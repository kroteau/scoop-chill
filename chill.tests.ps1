#requires -Version 5.1
# Self-checks for the chill engine, using temporary state and mocked Scoop calls.
param([string]$Lib = "$PSScriptRoot\chill-lib.ps1")

. $Lib

# Keep the command entrypoint's syntax within its declared PowerShell baseline.
# Scoop supplies $coreRoot, so parsing is the standalone check available here.
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\scoop-chill.ps1", [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -ne 0) { throw "regression: scoop-chill.ps1 does not parse: $($parseErrors.Message -join '; ')" }

# Find-ChillManifest reaches for scoop's bucket helpers, which are absent here.
# The missing-state check below only needs it to find nothing.
function Get-LocalBucket { @() }

$now = Get-Date

# A hold the user placed must be left alone. scoop's hold flag says an app is
# held but not by whom, so the state file's ScriptHeld is what tells the two apart.
$heldEntry  = @{ TargetDate = $now.AddDays(-30); ScriptHeld = $false }
$heldStatus = @{ name = 'testpkg'; hold = $true }
$decision   = Get-ChillDecision $heldEntry $heldStatus $now.AddDays(-7) $false
if ($decision.Action -ne 'ManualHold') { throw "regression: user hold reports $($decision.Action), expected ManualHold" }

# A hold this command placed is ours to release, not a manual hold.
$ourEntry = @{ TargetDate = $now.AddDays(-30); ScriptHeld = $true }
$decision = Get-ChillDecision $ourEntry $heldStatus $now.AddDays(-7) $false
if ($decision.Action -ne 'Ready') { throw "regression: own hold reports $($decision.Action), expected Ready" }

'ok: manual hold distinguished from a hold this command placed'

# Decision core: the age boundary and forcing.
$cutoff = $now.AddDays(-7)
$plain  = @{ name = 'testpkg'; hold = $false }

# At exactly the cutoff the version is not yet old enough; one second older it is.
$d = Get-ChillDecision @{ TargetDate = $cutoff; ScriptHeld = $true } $plain $cutoff $false
if ($d.Action -ne 'Held') { throw "regression: TargetDate at cutoff reports $($d.Action), expected Held" }
$d = Get-ChillDecision @{ TargetDate = $cutoff.AddSeconds(-1); ScriptHeld = $true } $plain $cutoff $false
if ($d.Action -ne 'Ready') { throw "regression: TargetDate past cutoff reports $($d.Action), expected Ready" }

# --force bypasses both the age gate and a manual hold.
$d = Get-ChillDecision @{ TargetDate = $now; ScriptHeld = $false } @{ name = 'testpkg'; hold = $true } $cutoff $true
if ($d.Action -ne 'Forced') { throw "regression: forced reports $($d.Action), expected Forced" }

# No target is never ready on its own.
$d = Get-ChillDecision @{ ScriptHeld = $false } $plain $cutoff $false
if ($d.Action -ne 'Held') { throw "regression: an app with no target reports $($d.Action), expected Held" }

'ok: decision core - age boundary, force'

# Recording a hold must not erase the proxy or the versions seen, and drops the
# fields of older releases, including a FirstSeen that came from git.
$roundTripDir = Join-Path ([System.IO.Path]::GetTempPath()) "chill-state-$([guid]::NewGuid())"
try {
    New-Item $roundTripDir -ItemType Directory -Force | Out-Null
    Write-ChillJson @{ Proxy = $true; Version = '2.0'; FirstSeen = '2026-01-01T12:00:00Z'; PinnedVersion = '1.5'; PinnedDate = '2026-09-01T12:00:00Z'; Seen = @{ '2.0' = '2026-09-01T12:00:00+03:00'; '2.1' = 'not a date' } } "$roundTripDir\testpkg.json"
    Update-ChillState 'testpkg' $roundTripDir @{ ScriptHeld = $true } | Out-Null
    $stored = Get-ChillState 'testpkg' $roundTripDir
    $entry  = ConvertTo-ChillEntry $stored
    if (-not $entry.Proxy -or -not $entry.ScriptHeld) { throw 'regression: a hold write erased other state' }
    if ($entry.Seen['2.0'] -ne [datetime]::Parse('2026-09-01T12:00:00+03:00', [cultureinfo]::InvariantCulture)) { throw "regression: a hold write changed when 2.0 was seen to '$($entry.Seen['2.0'])'" }
    if ($entry.Seen.ContainsKey('2.1')) { throw 'regression: an unreadable seen date reads as seen' }
    if (@($stored.Keys | Where-Object { $_ -notin 'ScriptHeld', 'Proxy', 'Seen' })) { throw "regression: old fields survived a write: $($stored.Keys -join ', ')" }
    $missing = ConvertTo-ChillEntry $null
    if ($missing.ScriptHeld -or $missing.Seen.Count) { throw 'regression: missing state reads as held or seen' }
} finally {
    if (Test-Path $roundTripDir) { Remove-Item $roundTripDir -Recurse -Force }
}

'ok: the proxy and seen versions survive a hold write, and old fields do not'

# A version gets the date chill first saw it, never a later one; versions out
# of question are left out, so they drop from state on the next write.
$recorded = @{ '1.0' = $now.AddDays(-30); '0.9' = $now.AddDays(-60) }
$firstSeen = Get-ChillFirstSeen $recorded @('2.0', '1.0', $null, '2.0') $now
if ($firstSeen.Dates['1.0'] -ne $now.AddDays(-30) -or $firstSeen.Dates['2.0'] -ne $now) { throw 'regression: first-seen dates are wrong' }
if ($firstSeen.Dates.ContainsKey('0.9') -or ($firstSeen.Unrecorded -join ',') -ne '2.0') { throw "regression: first-seen kept '$($firstSeen.Dates.Keys -join ',')', new '$($firstSeen.Unrecorded -join ',')'" }

'ok: a version keeps the date it was first seen'

# Only fields that change what is installed or run are compared, at the top
# level and per architecture; notes, checkver and the like are not.
$released = '{"version":"1.0","url":"https://x/A.zip","hash":"h","notes":"a","checkver":"x","architecture":{"64bit":{"url":"https://x/b.zip"}}}' | ConvertFrom-Json
$edited   = '{"version":"1.0","url":"https://x/A.zip","hash":"h","notes":"b","autoupdate":{},"architecture":{"64bit":{"url":"https://x/b.zip"}}}' | ConvertFrom-Json
$moved    = '{"version":"1.0","url":"https://x/a.zip","hash":"h","depends":"x","architecture":{"64bit":{"url":"https://x/b.zip","installer":{"script":"calc"}}}}' | ConvertFrom-Json
$before = Get-ChillInstallFields $released
$after  = Get-ChillInstallFields $edited
if (@(@($before.Keys) + @($after.Keys) | Sort-Object -Unique | Where-Object { $before[$_] -cne $after[$_] }).Count) { throw 'regression: an edit to notes or checkver reads as an install change' }
$after   = Get-ChillInstallFields $moved
$changed = @(@($before.Keys) + @($after.Keys) | Sort-Object -Unique | Where-Object { $before[$_] -cne $after[$_] })
if (($changed -join ',') -ne 'architecture.64bit.installer,depends,url') { throw "regression: install changes read as '$($changed -join ',')'" }

'ok: install fields cover scripts, links and dependencies, not notes'

# Shared settings are merged into one persistent file: recording a refresh must
# not erase the proxy, and changing the proxy must not erase the refresh.
$settingsDir = Join-Path ([System.IO.Path]::GetTempPath()) "chill-settings-$([guid]::NewGuid())"
try {
    Set-ChillSetting 'Proxy' 'proxy.test:8080' $settingsDir
    Set-ChillSetting 'LastRefresh' '2026-08-20T01:02:03Z' $settingsDir
    $settings = Get-ChillSettings $settingsDir
    if ($settings -isnot [hashtable]) { throw "regression: settings read as $($settings.GetType().Name), expected Hashtable" }
    if ($settings.Proxy -ne 'proxy.test:8080') { throw 'regression: refresh write erased proxy setting' }
    if ((ConvertTo-ChillDate $settings.LastRefresh).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -ne '2026-08-20T01:02:03Z') {
        throw 'regression: proxy write erased refresh setting'
    }
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $settingsDir '_scoop_chill.json'))
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw 'regression: state JSON was written with a UTF-8 BOM'
    }
} finally {
    if (Test-Path $settingsDir) { Remove-Item $settingsDir -Recurse -Force }
}

'ok: persistent proxy and refresh settings survive merged writes'

# The scriptblock handed to Invoke-ChillProxied must still see the functions
# defined alongside it. .GetNewClosure() binds it to a dynamic module instead,
# whose lookup skips the script scope, and every chill function goes missing.
function Invoke-ChillAppUpdate([object]$result, [hashtable]$options) { "updated $($result.Name)" }
$row = [pscustomobject]@{ Name = 'testpkg' }
$got = Invoke-ChillProxied $null { Invoke-ChillAppUpdate $row @{} }
if ($got -ne 'updated testpkg') { throw "regression: proxied action did not run, got '$got'" }

'ok: the proxied action resolves functions in the calling scope'

# The proxy is scoped to one action: whatever it was set to must come back,
# including when the action throws.
$scoopConfig = [pscustomobject]@{}
function setup_proxy { [Net.WebRequest]::DefaultWebProxy = [Net.WebProxy]::new('http://set-by-setup-proxy:1') }
$before = [Net.WebRequest]::DefaultWebProxy
try { Invoke-ChillProxied 'http://example:8080' { throw 'update blew up' } } catch { }
if ([Net.WebRequest]::DefaultWebProxy -ne $before) { throw 'regression: proxy not restored after a failed action' }
if ($scoopConfig.proxy) { throw "regression: proxy left in the config as '$($scoopConfig.proxy)'" }

'ok: the proxy is restored even when the update throws'

# scoop's update must get each option as itself, with and without the $force
# that scoop #6730 put third.
$options = @{ Quiet = $true; Independent = $false; Suggested = @{}; UseCache = $false; CheckHash = $false }
foreach ($signature in @(
    '$app, $global, $force = $false, $quiet = $false, $independent, $suggested, $use_cache = $true, $check_hash = $true',
    '$app, $global, $quiet = $false, $independent, $suggested, $use_cache = $true, $check_hash = $true'
)) {
    . ([scriptblock]::Create("function update($signature) { `$PSBoundParameters }"))
    $bound = Invoke-ChillScoopUpdate 'testpkg' $options
    if ($bound.app -ne 'testpkg' -or $bound.global -ne $false -or $bound.ContainsKey('force') -or $bound.quiet -ne $true -or $bound.independent -isnot [bool] -or $bound.independent -or $bound.suggested -isnot [hashtable] -or $bound.use_cache -ne $false -or $bound.check_hash -ne $false) {
        throw "regression: update($signature) got $(($bound.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    }
}

'ok: scoop''s update gets each option by name, before and after scoop #6730'

# scoop's setup_proxy builds "http://$address" itself, so a stored scheme is one
# scheme too many and routes nowhere.
foreach ($pair in @(
    @{ In = 'http://proxy.test:8080';  Out = 'proxy.test:8080' },
    @{ In = 'https://proxy.test:8080'; Out = 'proxy.test:8080' },
    @{ In = 'proxy.test:8080';         Out = 'proxy.test:8080' },
    @{ In = 'bob:pw@proxy.test:3128';  Out = 'bob:pw@proxy.test:3128' }
)) {
    $got = ConvertTo-ChillProxyAddress $pair.In
    if ($got -ne $pair.Out) { throw "regression: '$($pair.In)' normalized to '$got', expected '$($pair.Out)'" }
}

'ok: a proxy url with a scheme is reduced to scoop''s host:port form'

# Bucket reset, against a throwaway repo rather than a real bucket: a modified
# tracked file and an untracked one must both be reported, and both be gone
# afterwards. Redefines the stubs above; every check that needed them has run.
$repo = Join-Path ([System.IO.Path]::GetTempPath()) "chill reset $([guid]::NewGuid())"
function Get-LocalBucket { @('testbucket') }
function Find-BucketDirectory([string]$name, [switch]$Root) { $repo }
try {
    New-Item $repo -ItemType Directory | Out-Null
    git -C $repo init -q
    Write-ChillUtf8 '{"version":"1.0"}' "$repo\app.json"
    git -C $repo add app.json
    git -C $repo -c user.email=t@t -c user.name=t commit -q -m add

    # Exercise the history reader across a real redirected git process. The
    # spaced repository path also verifies native argument quoting.
    $hashes = [System.Collections.Generic.List[string]]::new()
    $hashes.Add((git -C $repo rev-parse HEAD))
    $versions = Get-ChillVersionsAt $repo 'app.json' $hashes
    if ($versions[$hashes[0]] -ne '1.0') { throw "regression: version reader found '$($versions[$hashes[0]])', expected 1.0" }

    # Only the top-level version counts, as Scoop reads it, through a BOM; a
    # manifest that does not parse has none.
    $manifests = @(
        @{ Text = '{"notes":{"version":"1.9"},"version":"2.0"}'; Expected = '2.0' },
        @{ Text = "$([char]0xFEFF){`"version`":`"2.1`"}";         Expected = '2.1' },
        @{ Text = '{"version":"2.2",';                            Expected = $null },
        @{ Text = '{"architecture":{"version":"2.3"}}';           Expected = $null }
    )
    # Committed, then HEAD put back where the reset check expects it; the
    # commits stay readable by hash.
    $hashes = [System.Collections.Generic.List[string]]::new()
    $head   = git -C $repo rev-parse HEAD
    foreach ($manifest in $manifests) {
        Write-ChillUtf8 $manifest.Text "$repo\app.json"
        git -C $repo -c user.email=t@t -c user.name=t commit -q -am manifest
        $hashes.Add((git -C $repo rev-parse HEAD))
    }
    git -C $repo reset -q --hard $head
    $versions = Get-ChillVersionsAt $repo 'app.json' $hashes
    for ($i = 0; $i -lt $manifests.Count; $i++) {
        if ($versions[$hashes[$i]] -ne $manifests[$i].Expected) { throw "regression: version reader found '$($versions[$hashes[$i]])' in $($manifests[$i].Text)" }
    }

    if (Get-ChillDirtyBucket) { throw 'regression: a clean bucket reported as dirty' }

    'edited' | Set-Content "$repo\app.json"
    'stray'  | Set-Content "$repo\leftover.json"
    $dirty = @(Get-ChillDirtyBucket)
    if ($dirty.Count -ne 1) { throw "regression: expected 1 dirty bucket, got $($dirty.Count)" }
    if ($dirty[0].Changes.Count -ne 2) { throw "regression: expected 2 changes, got $($dirty[0].Changes.Count)" }

    if (-not (Reset-GitBucket $repo)) { throw 'regression: Reset-GitBucket reported failure' }
    if ((Get-Content "$repo\app.json") -ne '{"version":"1.0"}') { throw 'regression: tracked file not restored' }
    if (Test-Path "$repo\leftover.json") { throw 'regression: untracked file not removed' }
    if (Get-ChillDirtyBucket) { throw 'regression: bucket still dirty after a reset' }
} finally {
    # .git holds read-only objects that a plain Remove-Item refuses.
    Get-ChildItem $repo -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
    Remove-Item $repo -Recurse -Force
}

'ok: a dirty bucket is detected and reset to HEAD'

# scoop's bucket sync ignores a failed 'git pull', so chill checks each bucket
# itself: one that fetched and merged is current, one that could not fetch or
# could not merge is reported.
& {
    $syncRoot = Join-Path ([System.IO.Path]::GetTempPath()) "chill-sync-$([guid]::NewGuid())"
    function Get-LocalBucket { @('synced', 'dirty', 'offline') }
    function Find-BucketDirectory([string]$name, [switch]$Root) { Join-Path $syncRoot $name }
    function Invoke-Quietly { & git.exe @args 2>&1 | Out-Null }
    try {
        $origin = Join-Path $syncRoot 'origin'
        New-Item $origin -ItemType Directory -Force | Out-Null
        Invoke-Quietly -C $origin init -q
        Write-ChillUtf8 '{"version":"1.0"}' "$origin\app.json"
        Invoke-Quietly -C $origin add app.json
        Invoke-Quietly -C $origin -c user.email=t@t -c user.name=t commit -q -m one
        foreach ($name in Get-LocalBucket) { Invoke-Quietly clone -q $origin (Join-Path $syncRoot $name) }
        Write-ChillUtf8 '{"version":"2.0"}' "$origin\app.json"
        Invoke-Quietly -C $origin -c user.email=t@t -c user.name=t commit -q -am two
        Write-ChillUtf8 '{"version":"local-edit"}' (Join-Path $syncRoot 'dirty\app.json')
        Invoke-Quietly -C (Join-Path $syncRoot 'offline') remote set-url origin (Join-Path $syncRoot 'missing')

        $start = Get-Date
        foreach ($name in Get-LocalBucket) { Invoke-Quietly -C (Join-Path $syncRoot $name) pull -q }
        $unsynced = @(Get-ChillUnsyncedBucket $start)
        if (($unsynced.Bucket -join ',') -ne 'dirty,offline') { throw "regression: unsynced buckets read as '$($unsynced.Bucket -join ',')'" }
        if (!($unsynced | Where-Object Bucket -EQ 'dirty').IsDirty) { throw 'regression: a bucket blocked by local edits not reported as dirty' }
    } finally {
        Get-ChildItem $syncRoot -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item $syncRoot -Recurse -Force
    }
}

'ok: buckets a refresh could not fetch or merge are reported'

# A pathspec log of a file with fewer commits than requested walks the whole
# bucket, so a lookup near HEAD must ask for little and grow only on demand.
& {
    $repo = Join-Path ([System.IO.Path]::GetTempPath()) "chill-pages-$([guid]::NewGuid())"
    $requested = [System.Collections.Generic.List[int]]::new()
    function git {
        $count = $args | Where-Object { "$_" -like '--max-count=*' }
        if ($count) { $requested.Add([int]("$count" -replace '^--max-count=')) }
        & git.exe @args
    }
    try {
        New-Item $repo -ItemType Directory | Out-Null
        git.exe -C $repo init -q
        foreach ($v in 1..20) {
            Write-ChillUtf8 "{`"version`":`"$v`"}" "$repo\app.json"
            git.exe -C $repo add app.json
            git.exe -C $repo -c user.email=t@t -c user.name=t commit -q -m $v
        }
        Reset-ChillCache
        $file = @{ BucketRoot = $repo; RelPath = 'app.json' }
        $newer = @(Get-ChillNewerVersions $file '18')
        if (($newer.Version -join ',') -ne '20,19') { throw "regression: newer versions read as '$($newer.Version -join ',')'" }
        if ($requested[0] -gt 4) { throw "regression: first history page asked for $($requested[0]) commits" }
        $requested.Clear()
        if ((Measure-ChillVersionsBehind $file '1') -ne 19) { throw 'regression: deep lookup did not reach the oldest commit' }
        $doubling = @(for ($i = 1; $i -lt $requested.Count; $i++) { $requested[$i] -eq 2 * $requested[$i - 1] })
        if ($doubling -contains $false) { throw "regression: history pages did not double: $($requested -join ',')" }
    } finally {
        Get-ChildItem $repo -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item $repo -Recurse -Force
        Reset-ChillCache
    }
}

'ok: history is read in small pages that double on demand'

& {
    $ErrorActionPreference = 'Stop'
    . $Lib
    $targets = @(ConvertTo-ChillTargets @('claude-code@2.1.280', 'ordinary'))
    if ($targets[0].Name -ne 'claude-code' -or $targets[0].Version -ne '2.1.280' -or $targets[1].Version) {
        throw 'regression: app/version parsing failed'
    }
    foreach ($bad in @('app@', '@1.0', 'app@1@2', '*@1.0', '../app@1.0')) {
        $rejected = $false
        try { ConvertTo-ChillTargets @($bad) | Out-Null } catch { $rejected = $true }
        if (!$rejected) { throw "regression: accepted invalid target $bad" }
    }
    $rejected = $false
    try { ConvertTo-ChillTargets @('app@1.0', 'APP@2.0') | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'regression: conflicting targets accepted' }
    'ok: version target parsing rejects malformed and duplicate app arguments'

    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\scoop-chill.ps1", [ref]$null, [ref]$null)
    foreach ($name in @('Get-ChillReport', 'Show-ChillReport', 'Save-ChillFirstSeen', 'Invoke-ChillRun', 'Confirm-ChillWrite')) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "chill-version-$([guid]::NewGuid())"
    $repo = Join-Path $testRoot 'bucket'
    $stateDir = Join-Path $testRoot 'state'
    $now = [datetime]'2026-09-24T12:00:00Z'
    $dryRun = $false
    $updateOptions = @{}
    $fixture = @{ Installed = '3.0'; Hold = $false; Url = $null; Fail = $false; Skip = $false }
    $updates = [System.Collections.Generic.List[object]]::new()
    function Get-LocalBucket { @('fixture') }
    function Find-BucketDirectory { $repo }
    function Select-CurrentVersion { $fixture.Installed }
    function install_info { @{ bucket = 'fixture'; url = $fixture.Url } }
    function app_status($name) {
        if ($name -ne 'app') { throw "regression: installed lookup received $name" }
        @{ installed = $true; outdated = ($fixture.Installed -ne '3.0'); version = $fixture.Installed; latest_version = '3.0'; hold = $fixture.Hold }
    }
    function Set-ChillHold($name, $held) { $fixture.Hold = $held; return $true }
    function Invoke-ChillScoopUpdate($name, $options) {
        $manifest = Get-Content "$repo\app.json" -Raw | ConvertFrom-Json
        $updates.Add($manifest)
        if ($fixture.Fail) { throw 'simulated update failure' }
        if (!$fixture.Skip) { $fixture.Installed = $manifest.version }
    }
    function error($message) { throw $message }
    # Record a version as seen on $date, as a run on that day would have.
    function Add-SeenVersion($name, $version, $date) {
        $seen = (ConvertTo-ChillEntry (Get-ChillState $name $stateDir)).Seen
        if (!$seen.ContainsKey($version)) { $seen[$version] = ConvertTo-ChillDate $date }
        Update-ChillState $name $stateDir @{ Seen = $seen } | Out-Null
    }
    function Commit-VersionFixture($version, $hash, $date) {
        Write-ChillUtf8 "{`"version`":`"$version`",`"hash`":`"$hash`"}" "$repo\app.json"
        git -C $repo add app.json
        git -C $repo -c user.name=test -c user.email=test@example.invalid commit -q --date=$date -m $hash
        if ($LASTEXITCODE -ne 0) { throw 'version fixture commit failed' }
        Add-SeenVersion 'app' $version $date
        Reset-ChillCache
    }
    try {
        New-Item $repo -ItemType Directory -Force | Out-Null
        git -C $repo init -q
        Commit-VersionFixture '1.0' 'original' '2026-08-01T12:00:00Z'
        Commit-VersionFixture '1.0' 'repushed' '2026-08-02T12:00:00Z'
        Commit-VersionFixture '2.0' 'middle' '2026-09-01T12:00:00Z'
        Commit-VersionFixture '3.0' 'latest' '2026-09-23T12:00:00Z'
        $latestHash = (Get-FileHash "$repo\app.json").Hash

        $rows = @(Get-ChillReport @('app@2.0') 7 @())
        if ($rows.Count -ne 1 -or $rows[0].Action -ne 'Ready' -or $rows[0].TargetVersion -ne '2.0') { throw 'regression: historical downgrade not ready' }
        $display = Show-ChillReport $rows 6>&1 | Out-String
        if ($display -notmatch 'Target' -or $display -notmatch '2.0') { throw 'regression: requested version missing from report' }
        $dryRun = $true
        $beforeState = (Get-FileHash "$stateDir\app.json").Hash
        Invoke-ChillRun $rows
        if ($updates.Count -or (Get-FileHash "$stateDir\app.json").Hash -ne $beforeState -or $fixture.Hold) { throw 'regression: version dry-run changed state' }
        $dryRun = $false
        Invoke-ChillRun $rows
        if ($fixture.Installed -ne '2.0' -or $updates[-1].hash -ne 'middle') { throw 'regression: historical manifest not used' }
        if ((Get-FileHash "$repo\app.json").Hash -ne $latestHash) { throw 'regression: manifest not restored' }
        $saved = Get-ChillState 'app' $stateDir
        if (!$fixture.Hold -or !$saved.ScriptHeld) { throw 'regression: a target short of latest was left unheld' }

        $calls = $updates.Count
        $beforeState = (Get-FileHash "$stateDir\app.json").Hash
        $current = @(Get-ChillReport @('app@2.0') 7 @('app@2.0'))
        if ($current[0].Action -ne 'Current') { throw 'regression: installed target not reported as current' }
        Invoke-ChillRun $current
        if ($updates.Count -ne $calls -or (Get-FileHash "$stateDir\app.json").Hash -ne $beforeState) { throw 'regression: current target caused writes' }

        $young = @(Get-ChillReport @('app@3.0') 7 @())
        if ($young[0].Action -ne 'Held') { throw 'regression: target age gate ignored' }
        # The hold the downgrade left behind, now read as the user's own.
        Update-ChillState 'app' $stateDir @{ ScriptHeld = $false } | Out-Null
        $held = @(Get-ChillReport @('app@1.0') 7 @())
        if ($held[0].Action -ne 'ManualHold') { throw 'regression: version target ignored manual hold' }
        $forced = @(Get-ChillReport @('app@3.0') 7 @('app@3.0'))
        if ($forced[0].Action -ne 'Forced') { throw 'regression: version force did not bypass age/hold' }
        Invoke-ChillRun $forced
        if ($fixture.Installed -ne '3.0') { throw 'regression: forced target did not install' }
        # -f overrides a manual hold once; the hold itself is the user's to keep.
        if (!$fixture.Hold -or (Get-ChillState 'app' $stateDir).ScriptHeld) { throw 'regression: manual hold not restored, as the user''s, after a forced update' }
        $fixture.Installed = '2.0'
        $fixture.Fail = $true
        try { Invoke-ChillRun @(Get-ChillReport @('app@3.0') 7 @('app@3.0')) } catch { }
        $fixture.Fail = $false
        if ($fixture.Installed -ne '2.0' -or !$fixture.Hold -or (Get-ChillState 'app' $stateDir).ScriptHeld) { throw 'regression: manual hold not restored after a failed forced update' }
        $fixture.Hold = $false
        $fixture.Installed = '3.0'

        Invoke-ChillRun @(Get-ChillReport @('app@1.0') 7 @() 3>$null)
        if ($fixture.Installed -ne '1.0' -or $updates[-1].hash -ne 'repushed') { throw 'regression: target did not use the version''s newest manifest' }

        $out = @(Get-ChillReport @('app@9.0') 7 @('app@9.0') 3>&1)
        $missing = @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        if ($missing.Count -or !$warnings) { throw 'regression: missing target fell back to latest' }
        $fixture.Url = 'https://example.invalid/app.json'
        if (@(Get-ChillReport @('app@2.0') 7 @() 3>$null).Count) { throw 'regression: URL install accepted historical target' }
        $fixture.Url = $null

        $fixture.Fail = $true
        $failed = $false
        try { Invoke-ChillAppUpdate $rows[0] @{} } catch { $failed = $true }
        if (!$failed -or (Get-FileHash "$repo\app.json").Hash -ne $latestHash) { throw 'regression: failed update did not restore manifest' }
        $fixture.Fail = $false
        $fixture.Skip = $true
        $out = @(Invoke-ChillHistoricalUpdate 'app' $rows[0].TargetHash $rows[0].TargetFile @{} 3>&1)
        $applied = $out -contains $true
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        if ($applied -or !$warnings) { throw 'regression: skipped update reported success' }
        $fixture.Skip = $false
        Write-ChillUtf8 '{"version":"local-edit"}' "$repo\app.json"
        $calls = $updates.Count
        Invoke-ChillAppUpdate $rows[0] @{} 3>$null
        if ($updates.Count -ne $calls -or (Get-Content "$repo\app.json" -Raw) -notmatch 'local-edit') { throw 'regression: dirty manifest was overwritten' }
        'ok: version targets respect gates, use real historical manifests, and restore bucket files'
    } finally {
        $resolved = [System.IO.Path]::GetFullPath($testRoot)
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (!$resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe version fixture cleanup path' }
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}

& {
    # Real bucket history and state; Scoop installation/update operations are mocked.
    $ErrorActionPreference = 'Stop'
    . $Lib
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\scoop-chill.ps1", [ref]$null, [ref]$null)
    foreach ($name in @('Get-ChillReport', 'Show-ChillReport', 'Save-ChillFirstSeen', 'Invoke-ChillRun', 'Confirm-ChillWrite')) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "chill-rewrite-flow-$([guid]::NewGuid())"
    $repo = Join-Path $testRoot 'bucket'
    $stateDir = Join-Path $testRoot 'state'
    $now = [datetime]'2026-09-20T12:00:00'
    $dryRun = $false
    $updateOptions = @{}
    $updates = [System.Collections.Generic.List[string]]::new()
    $holds = @{}
    # 1.26.0 predates the fixture's history, so only latest is a candidate.
    $installed = @{ go = '1.26.0'; ordinary = '1.26.0' }
    function Get-LocalBucket { @('fixture') }
    function Find-BucketDirectory { $repo }
    function Select-CurrentVersion { param($AppName) $installed[$AppName] }
    function install_info { @{ bucket = 'fixture' } }
    function installed_apps { @('go', 'ordinary') }
    function app_status($name) {
        @{ installed = $true; outdated = ($installed[$name] -ne '1.27.1'); version = $installed[$name]; latest_version = '1.27.1'; hold = [bool]$holds[$name] }
    }
    function Set-ChillHold($name, $held) { $holds[$name] = $held; return $true }
    function Invoke-ChillScoopUpdate($name, $options) {
        $manifest = Get-Content "$repo\$name.json" -Raw | ConvertFrom-Json
        $updates.Add("${name}:$($manifest.hash)")
        $installed[$name] = $manifest.version
    }
    function error($message) { throw $message }
    function Commit-Fixture($date, $message) {
        git -C $repo add .
        git -C $repo -c user.name=test -c user.email=test@example.invalid commit -q --date=$date -m $message
        if ($LASTEXITCODE -ne 0) { throw 'fixture commit failed' }
        Reset-ChillCache
    }
    try {
        New-Item $repo -ItemType Directory -Force | Out-Null
        git -C $repo init -q
        Write-ChillUtf8 '{"version":"1.27.1","hash":"original"}' "$repo\go.json"
        Write-ChillUtf8 '{"version":"1.27.1","hash":"unchanged"}' "$repo\ordinary.json"
        Commit-Fixture '2026-09-01T23:28:00+03:00' 'initial versions'
        # Seen by a run on the day it was committed.
        foreach ($name in 'go', 'ordinary') { Update-ChillState $name $stateDir @{ Seen = @{ '1.27.1' = '2026-09-01T23:28:00+03:00' } } | Out-Null }
        Write-ChillUtf8 '{"version":"1.27.1","hash":"replacement"}' "$repo\go.json"
        Commit-Fixture '2026-09-05T09:06:00+03:00' 'rewrite go without changing version'
        $headManifest = (Get-FileHash "$repo\go.json").Hash

        if ($holds.Count -or (Get-ChillState 'go' $stateDir).ScriptHeld) { throw 'fixture unexpectedly has holds' }
        $out = @(Get-ChillReport (installed_apps) 7 @() 3>&1)
        $rows = @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        $go = $rows | Where-Object Name -EQ 'go'
        if ($go.Action -ne 'Held' -or $go.TargetVersion) { throw "regression: rewritten latest reports $($go.Action) '$($go.TargetVersion)', expected Held with no target" }
        if (!($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and "$_" -match '^go: 1\.27\.1''s hash changed on .*run: scoop chill go@1\.27\.1$' })) { throw 'regression: no warning, naming the version, for a skipped rewrite' }
        $display = Show-ChillReport $rows 6>&1 | Out-String
        if ($display -notmatch '\bgo\b' -or $display -notmatch 'ordinary') { throw 'regression: report hid an app' }
        Invoke-ChillRun $rows
        if (($updates -join ',') -ne 'ordinary:unchanged') { throw "regression: '*' flow installed $updates" }
        if ((Get-FileHash "$repo\go.json").Hash -ne $headManifest) { throw 'regression: bucket manifest changed' }
        'ok: a run over every app skips a version whose download was replaced'

        # Naming the app changes nothing: only naming the version takes the
        # replaced download, and says so.
        $updates.Clear()
        Invoke-ChillRun @(Get-ChillReport @('go') 7 @() 3>$null)
        if ($updates.Count) { throw "regression: named run installed $updates, expected the rewrite skipped" }
        $out = @(Get-ChillReport @('go@1.27.1') 7 @() 3>&1)
        $rows = @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        if ($rows[0].Action -ne 'Ready' -or !($out | Where-Object { "$_" -match '^go: 1\.27\.1''s hash changed on .*installing the changed manifest' })) { throw "regression: requested rewrite reports $($rows[0].Action) without its warning" }
        Invoke-ChillRun $rows
        if (($updates -join ',') -ne 'go:replacement') { throw "regression: requested version installed $updates, expected the replacement" }
        if ((Get-FileHash "$repo\go.json").Hash -ne $headManifest) { throw 'regression: bucket manifest changed' }
        'ok: naming the app skips the rewrite; naming the version takes it, with a warning'

        $updates.Clear()
        $installed.go = '1.26.0'
        $holds.go = $true
        Update-ChillState 'go' $stateDir @{ ScriptHeld = $true } | Out-Null
        $dryRun = $true
        Invoke-ChillRun @(Get-ChillReport @('go') 7 @('go'))
        if ($updates.Count) { throw 'forced dry-run called the updater' }
        $dryRun = $false
        $out = @(Get-ChillReport @('go') 7 @('go') 3>&1)
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$_" })
        if (!($warnings -match '^go: -f installs 1\.27\.1, ignoring the age gate and holds\.$') -or !($warnings -match 'installing the changed manifest')) { throw "regression: forced run warned '$warnings'" }
        Invoke-ChillRun @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        if (($updates -join ',') -ne 'go:replacement' -or $holds.go) { throw 'forced update did not reach Scoop or release the hold' }
        'ok: forced dry-run does not update; forced run installs latest, says so, and releases the hold'
    } finally {
        $resolved = [System.IO.Path]::GetFullPath($testRoot)
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe fixture cleanup path' }
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}

& {
    # Updates step through bucket history: an outdated app moves to the newest
    # version past the age gate, never straight to a latest that is still young.
    $ErrorActionPreference = 'Stop'
    . $Lib
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\scoop-chill.ps1", [ref]$null, [ref]$null)
    foreach ($name in @('Get-ChillReport', 'Show-ChillReport', 'Save-ChillFirstSeen', 'Invoke-ChillRun', 'Confirm-ChillWrite')) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "chill-series-$([guid]::NewGuid())"
    $repo = Join-Path $testRoot 'bucket'
    $stateDir = Join-Path $testRoot 'state'
    $now = [datetime]'2026-11-06T12:00:00Z'
    $dryRun = $false
    $updateOptions = @{}
    $installed = @{}
    $latest = @{}
    $holds = @{}
    $skip = @{ Update = $false }
    $updates = [System.Collections.Generic.List[string]]::new()
    function Get-LocalBucket { @('fixture') }
    function Find-BucketDirectory { $repo }
    function Select-CurrentVersion { param($AppName) $installed[$AppName] }
    function install_info { @{ bucket = 'fixture' } }
    function app_status($name) {
        @{ installed = $true; outdated = ($installed[$name] -ne $latest[$name]); version = $installed[$name]; latest_version = $latest[$name]; hold = [bool]$holds[$name] }
    }
    function Set-ChillHold($name, $held) { $holds[$name] = $held; return $true }
    function Invoke-ChillScoopUpdate($name, $options) {
        $manifest = Get-Content "$repo\$name.json" -Raw | ConvertFrom-Json
        $updates.Add("${name}:$($manifest.hash)$(if ($manifest.notes) { "+$($manifest.notes)" })")
        if (!$skip.Update) { $installed[$name] = $manifest.version }
    }
    function error($message) { throw $message }
    # Record a version as seen on $date, as a run on that day would have.
    function Add-SeenVersion($name, $version, $date) {
        $seen = (ConvertTo-ChillEntry (Get-ChillState $name $stateDir)).Seen
        if (!$seen.ContainsKey($version)) { $seen[$version] = ConvertTo-ChillDate $date }
        Update-ChillState $name $stateDir @{ Seen = $seen } | Out-Null
    }
    function Commit-Fixture($name, $version, $hash, $date, $notes) {
        $notesField = if ($notes) { ",`"notes`":`"$notes`"" } else { '' }
        Write-ChillUtf8 "{`"version`":`"$version`",`"hash`":`"$hash`"$notesField}" "$repo\$name.json"
        git -C $repo add "$name.json"
        git -C $repo -c user.name=test -c user.email=test@example.invalid commit -q --date=$date -m $hash
        if ($LASTEXITCODE -ne 0) { throw 'series fixture commit failed' }
        $latest[$name] = $version
        Add-SeenVersion $name $version $date
        Reset-ChillCache
    }
    try {
        New-Item $repo -ItemType Directory -Force | Out-Null
        git -C $repo init -q
        Commit-Fixture 'crush' '0.98.2' 'h0.98.2' '2026-10-23T12:00:00Z'
        Commit-Fixture 'crush' '0.99.0' 'h0.99.0' '2026-10-29T12:00:00Z'
        Commit-Fixture 'crush' '0.100.0' 'h0.100.0' '2026-11-05T12:00:00Z'
        $installed.crush = '0.98.2'
        $headManifest = (Get-FileHash "$repo\crush.json").Hash

        # The reported case: 0.99.0 has aged, 0.100.0 has not, and no state
        # remembers 0.99.0. History alone must route the update through it.
        $rows = @(Get-ChillReport @('crush') 7 @())
        if ($rows.Count -ne 1 -or $rows[0].Action -ne 'Ready' -or $rows[0].TargetVersion -ne '0.99.0') {
            throw "regression: crush reports $($rows[0].Action) for '$($rows[0].TargetVersion)', expected Ready for 0.99.0"
        }
        Invoke-ChillRun $rows
        if ($installed.crush -ne '0.99.0' -or $updates[-1] -ne 'crush:h0.99.0') { throw 'regression: aged step 0.99.0 not installed from its own manifest' }
        if ((Get-FileHash "$repo\crush.json").Hash -ne $headManifest) { throw 'regression: manifest not restored after a step' }
        if (!$holds.crush -or !(Get-ChillState 'crush' $stateDir).ScriptHeld) { throw 'regression: app short of latest left unheld after a step' }
        'ok: an outdated app steps to the aged version before a young latest'

        $calls = $updates.Count
        $beforeState = Get-Content "$stateDir\crush.json" -Raw
        $rows = @(Get-ChillReport @('crush') 7 @())
        if ($rows[0].Action -ne 'Held' -or $rows[0].TargetVersion -ne '0.100.0') { throw 'regression: young latest not held as the next step' }
        Invoke-ChillRun $rows
        if ($updates.Count -ne $calls -or (Get-Content "$stateDir\crush.json" -Raw) -ne $beforeState) { throw 'regression: a held run changed state' }
        'ok: a held run writes nothing'

        # A hold lost outside chill, by 'scoop unhold' or a reinstall, while the
        # state still records it as chill's, must be placed again.
        $holds.crush = $false
        Invoke-ChillRun @(Get-ChillReport @('crush') 7 @())
        if (!$holds.crush -or !(Get-ChillState 'crush' $stateDir).ScriptHeld) { throw 'regression: a hold lost outside chill was not placed again' }
        'ok: a hold recorded as chill''s but missing from scoop is restored'

        # Several aged versions: take the newest of them, not each in turn.
        Commit-Fixture 'jump' '1' 'v1' '2026-08-01T12:00:00Z'
        Commit-Fixture 'jump' '2' 'v2' '2026-09-01T12:00:00Z'
        Commit-Fixture 'jump' '3' 'v3' '2026-10-01T12:00:00Z'
        Commit-Fixture 'jump' '4' 'v4' '2026-10-20T12:00:00Z'
        Commit-Fixture 'jump' '5' 'v5' '2026-11-05T12:00:00Z'
        $installed.jump = '1'
        Invoke-ChillRun @(Get-ChillReport @('jump') 7 @())
        if ($installed.jump -ne '4' -or $updates[-1] -ne 'jump:v4') { throw "regression: expected a jump to 4, installed $($installed.jump)" }
        'ok: the newest aged version is installed in one step'

        # An update that does not land keeps the hold.
        $now = [datetime]'2026-11-20T12:00:00Z'
        $skip.Update = $true
        Invoke-ChillRun @(Get-ChillReport @('crush') 7 @()) 3>$null
        $saved = Get-ChillState 'crush' $stateDir
        if (!$holds.crush -or !$saved.ScriptHeld) { throw 'regression: hold lost after an update that did not land' }
        $skip.Update = $false
        Invoke-ChillRun @(Get-ChillReport @('crush') 7 @())
        $saved = Get-ChillState 'crush' $stateDir
        if ($installed.crush -ne '0.100.0' -or $holds.crush -or $saved.ScriptHeld) { throw 'regression: completed update not recorded' }
        'ok: holds only move once an update lands'

        # A version whose download was replaced after its release is skipped,
        # with a warning, until a newer version passes the age gate; naming the
        # version takes it. A harmless edit is no rewrite.
        # Get-ChillReport is a plain function, without -WarningVariable, so
        # the warnings are taken from its output stream instead.
        function Get-Report($names) {
            $out = @(Get-ChillReport $names 7 @() 3>&1)
            [pscustomobject]@{
                Rows     = @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
                Warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$_" })
            }
        }
        foreach ($name in 'rwa', 'rwb', 'rwc', 'rwd') { Commit-Fixture $name '1.0' "${name}1.0" '2026-08-01T12:00:00Z'; $installed[$name] = '1.0' }
        Commit-Fixture 'rwa' '2.0' 'rwa2.0' '2026-09-01T12:00:00Z'
        foreach ($name in 'rwa', 'rwb', 'rwc') {
            Commit-Fixture $name '3.0' "${name}3.0" '2026-10-01T12:00:00Z'
            Commit-Fixture $name '3.0' "${name}3.0-replaced" '2026-10-05T12:00:00Z'
        }
        Commit-Fixture 'rwc' '4.0' 'rwc4.0' '2026-11-18T12:00:00Z'
        Commit-Fixture 'rwd' '2.0' 'rwd2.0' '2026-09-01T12:00:00Z' 'first'
        Commit-Fixture 'rwd' '2.0' 'rwd2.0' '2026-09-03T12:00:00Z' 'fixed'

        # An aged clean version older than the rewrite is taken.
        $report = Get-Report @('rwa')
        if (!($report.Warnings -match "^rwa: 3\.0's hash changed on 2026-10-05, after its release on 2026-10-01\. Skipped")) { throw "regression: rwa warned '$($report.Warnings)'" }
        Invoke-ChillRun $report.Rows
        if ($updates[-1] -ne 'rwa:rwa2.0') { throw "regression: rwa installed $($updates[-1]), expected 2.0" }

        # Nothing clean to take: held, with no target.
        $report = Get-Report @('rwb')
        if ($report.Rows[0].Action -ne 'Held' -or $report.Rows[0].TargetVersion -or !($report.Warnings -match '^rwb: 3\.0.*Skipped.*run: scoop chill rwb@3\.0$')) { throw 'regression: rwb not held with a warning' }
        $calls = $updates.Count
        Invoke-ChillRun $report.Rows
        if ($updates.Count -ne $calls) { throw 'regression: a skipped rewrite was installed' }
        # Naming the version takes the replaced download, still gated on its
        # release.
        $report = Get-Report @('rwb@3.0')
        if ($report.Rows[0].Indexed -ne '2026-10-01' -or !($report.Warnings -match "^rwb: 3\.0's hash changed on 2026-10-05, after its release on 2026-10-01; installing the changed manifest\.$")) { throw "regression: requested rwb warned '$($report.Warnings)', indexed $($report.Rows[0].Indexed)" }
        Invoke-ChillRun $report.Rows
        if ($updates[-1] -ne 'rwb:rwb3.0-replaced') { throw "regression: requested rwb installed $($updates[-1])" }

        # A newer clean version still too young: held for it, warning meanwhile.
        $report = Get-Report @('rwc')
        if ($report.Rows[0].Action -ne 'Held' -or $report.Rows[0].TargetVersion -ne '4.0' -or !($report.Warnings -match '^rwc: 3\.0')) { throw 'regression: rwc not held for 4.0 with a warning' }
        # Once it has aged, it is taken and the warning stops.
        $now = [datetime]'2026-11-30T12:00:00Z'
        $report = Get-Report @('rwc')
        if ($report.Warnings) { throw "regression: rwc still warns once 4.0 has aged: $($report.Warnings)" }
        Invoke-ChillRun $report.Rows
        if ($updates[-1] -ne 'rwc:rwc4.0') { throw "regression: rwc installed $($updates[-1]), expected 4.0" }
        $now = [datetime]'2026-11-20T12:00:00Z'

        # An edit that kept the download is not skipped, but still warned about,
        # and the newest manifest is installed.
        $report = Get-Report @('rwd')
        if (!($report.Warnings -match "^rwd: 2\.0's manifest was edited on 2026-09-03, after its release on 2026-09-01; nothing it installs or runs changed") -or $report.Rows[0].Action -ne 'Ready') {
            throw "regression: a harmless edit warned '$($report.Warnings)' and reports $($report.Rows[0].Action)"
        }
        Invoke-ChillRun $report.Rows
        if ($updates[-1] -ne 'rwd:rwd2.0+fixed') { throw "regression: rwd installed $($updates[-1]), expected the newest manifest" }

        # The audit's case: an aged version given a script and a binary after
        # its release, the download untouched, is skipped as a replaced
        # download is, and the warning names what changed.
        Commit-Fixture 'rwe' '1.0' 'rwe1.0' '2026-08-01T12:00:00Z'
        $installed.rwe = '1.0'
        Commit-Fixture 'rwe' '2.0' 'rwe2.0' '2026-09-01T12:00:00Z'
        Write-ChillUtf8 '{"version":"2.0","hash":"rwe2.0","post_install":"calc","architecture":{"64bit":{"bin":"evil.exe"}}}' "$repo\rwe.json"
        git -C $repo add rwe.json
        git -C $repo -c user.name=test -c user.email=test@example.invalid commit -q --date=2026-11-19T12:00:00Z -m rwe2.0-scripted
        Reset-ChillCache
        $report = Get-Report @('rwe')
        if ($report.Rows[0].Action -ne 'Held' -or $report.Rows[0].TargetVersion -or !($report.Warnings -match "^rwe: 2\.0's architecture\.64bit\.bin, post_install changed on 2026-11-19, after its release on 2026-09-01\. Skipped")) {
            throw "regression: a script added after release reports $($report.Rows[0].Action) '$($report.Rows[0].TargetVersion)', warned '$($report.Warnings)'"
        }
        $calls = $updates.Count
        Invoke-ChillRun $report.Rows
        if ($updates.Count -ne $calls) { throw 'regression: a script added after release was installed' }
        'ok: changed downloads, scripts and links are skipped until a newer version ages, taken when the version is named; other edits install with a warning'

        # Every row names the version it would install, and Indexed and Age
        # describe that version; Published describes latest.
        Commit-Fixture 'tbl' '1.0' 't1.0' '2026-08-01T12:00:00Z'
        Commit-Fixture 'tbl' '2.0' 't2.0' '2026-09-01T12:00:00Z'
        Commit-Fixture 'tbl' '3.0' 't3.0' '2026-10-01T12:00:00Z'
        Commit-Fixture 'tbl' '4.0' 't4.0' '2026-11-18T12:00:00Z'
        $installed.tbl = '1.0'
        function Get-TableRow($rows) {
            $text = Show-ChillReport $rows 6>&1 | Out-String
            $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
            [pscustomobject]@{ Header = $lines[0]; Line = ($lines | Where-Object { $_ -match '^tbl\b' } | Select-Object -First 1) }
        }
        function Assert-Row($row, $source, $version, $indexed, $age, $action, $cell) {
            $table = Get-TableRow @($row)
            if ($row.TargetSource -ne $source -or $row.TargetVersion -ne $version -or $row.Indexed -ne $indexed -or $row.Age -ne $age -or $row.Action -ne $action) {
                throw "regression: $source row is $($row.TargetSource) $($row.TargetVersion) '$($row.Indexed)' '$($row.Age)' $($row.Action)"
            }
            if ($row.Published -ne '2026-11-18') { throw "regression: $source row publishes latest as '$($row.Published)'" }
            if ($table.Line -notmatch [regex]::Escape($cell)) { throw "regression: $source row shows '$($table.Line)', expected '$cell'" }
        }

        $step = @(Get-ChillReport @('tbl') 7 @())[0]
        Assert-Row $step 'Step' '3.0' '2026-10-01' 50 'Ready' ' 3.0 (-1) '
        $header = (Get-TableRow @($step)).Header
        if ($header -notmatch '^Name\s+Installed\s+Latest\s+Published\s+Target\s+Indexed\s+Age\s+Action\s*$') { throw "regression: table header is '$header'" }

        Update-ChillState 'tbl' $stateDir @{ Proxy = $true } | Out-Null
        $proxied = @(Get-ChillReport @('tbl') 7 @())[0]
        if ((Get-TableRow @($proxied)).Line -notmatch 'Ready\^\s*$') { throw 'regression: proxy not marked on Action' }
        Update-ChillState 'tbl' $stateDir @{ Proxy = $false } | Out-Null

        Assert-Row @(Get-ChillReport @('tbl') 7 @('tbl'))[0] 'Latest' '4.0' '2026-11-18' 2 'Forced' ' 4.0 '
        Assert-Row @(Get-ChillReport @('tbl@2.0') 7 @())[0] 'Requested' '2.0' '2026-09-01' 80 'Ready' ' 2.0 (-2) '

        'ok: the table ties Indexed and Age to Target, with proxy and distance marks'

        # The audit's case: a version committed today, its author date set
        # back to January. Only chill's own first sight of it counts.
        Commit-Fixture 'late' '1.0' 'late1.0' '2026-08-01T12:00:00Z'
        $installed.late = '1.0'
        Write-ChillUtf8 '{"version":"2.0","hash":"late2.0"}' "$repo\late.json"
        git -C $repo add late.json
        git -C $repo -c user.name=test -c user.email=test@example.invalid commit -q --date=2026-01-01T12:00:00Z -m late2.0
        $latest.late = '2.0'
        Reset-ChillCache
        $rows = @(Get-ChillReport @('late') 7 @())
        if ($rows[0].Action -ne 'Held' -or $rows[0].TargetVersion -ne '2.0' -or $rows[0].Age -ne 0 -or $rows[0].Published -ne '2026-01-01') {
            throw "regression: a backdated version reports $($rows[0].Action) '$($rows[0].TargetVersion)' at age $($rows[0].Age)"
        }
        # A dry run records nothing, as a report or as a run.
        $beforeState = Get-Content "$stateDir\late.json" -Raw
        $dryRun = $true
        Save-ChillFirstSeen $rows
        Invoke-ChillRun $rows
        $dryRun = $false
        if ((Get-Content "$stateDir\late.json" -Raw) -ne $beforeState) { throw 'regression: a dry run recorded a version' }
        # A report records what it sees, and holds nothing.
        Save-ChillFirstSeen $rows
        $seen = (ConvertTo-ChillEntry (Get-ChillState 'late' $stateDir)).Seen
        if (($seen.Keys -join ',') -ne '2.0' -or $seen['2.0'] -ne $now -or $holds.late) {
            throw "regression: a report recorded '$($seen.Keys -join ',')' with late held: $($holds.late)"
        }
        Invoke-ChillRun $rows
        if (!$holds.late -or $installed.late -ne '1.0') { throw "regression: a held run left late at $($installed.late), held: $($holds.late)" }
        # Seen once, it keeps that date: the next run writes nothing.
        $beforeState = Get-Content "$stateDir\late.json" -Raw
        Invoke-ChillRun @(Get-ChillReport @('late') 7 @())
        if ((Get-Content "$stateDir\late.json" -Raw) -ne $beforeState) { throw 'regression: a second sight of a version was recorded' }
        $now = $now.AddDays(8)
        $rows = @(Get-ChillReport @('late') 7 @())
        if ($rows[0].Action -ne 'Ready' -or $rows[0].Age -ne 8) { throw "regression: a version seen 8 days ago reports $($rows[0].Action) at age $($rows[0].Age)" }
        Invoke-ChillRun $rows
        if ($installed.late -ne '2.0' -or $holds.late) { throw 'regression: an aged first sight did not install' }
        $now = [datetime]'2026-11-20T12:00:00Z'
        'ok: a backdated commit ages from when chill first saw it, recorded once by a report or a run, never by a dry run'

        # The audit's case: a new version whose manifest carries an aged
        # version's number nested ahead of its own. It is a new version, not
        # an edit of the aged one, so the aged one installs from its own commit.
        Commit-Fixture 'nest' '1.8' 'nest1.8' '2026-08-01T12:00:00Z'
        Commit-Fixture 'nest' '1.9' 'nest1.9' '2026-09-01T12:00:00Z'
        $installed.nest = '1.8'
        Write-ChillUtf8 '{"notes":{"version":"1.9"},"version":"2.0","hash":"nest2.0"}' "$repo\nest.json"
        git -C $repo add nest.json
        git -C $repo -c user.name=test -c user.email=test@example.invalid commit -q --date=2026-11-20T12:00:00Z -m nest2.0
        $latest.nest = '2.0'
        Reset-ChillCache
        $report = Get-Report @('nest')
        if ($report.Rows[0].Action -ne 'Ready' -or $report.Rows[0].TargetVersion -ne '1.9' -or $report.Warnings) {
            throw "regression: a nested version reports $($report.Rows[0].Action) '$($report.Rows[0].TargetVersion)', warned '$($report.Warnings)'"
        }
        Invoke-ChillRun $report.Rows
        if ($updates[-1] -ne 'nest:nest1.9' -or $installed.nest -ne '1.9') { throw "regression: a nested version installed $($updates[-1])" }
        'ok: a version nested in a manifest is not its version'

        # State from an older release, with a pin and a FirstSeen taken from
        # git, has no record of what chill saw: the app steps as any other,
        # without a word, every version aging from now.
        Write-ChillJson @{ Version = '4.0'; FirstSeen = '2026-08-01T12:00:00Z'; ScriptHeld = $holds.tbl; PinnedVersion = '2.0'; PinnedDate = '2026-09-01T12:00:00Z' } "$stateDir\tbl.json"
        $report = Get-Report @('tbl')
        if ($report.Warnings -or $report.Rows[0].TargetSource -ne 'Step' -or $report.Rows[0].TargetVersion -ne '2.0' -or $report.Rows[0].Action -ne 'Held' -or $report.Rows[0].Age -ne 0) {
            throw "regression: an old state changed the report: $($report.Rows[0].TargetSource) $($report.Rows[0].TargetVersion) $($report.Rows[0].Action) '$($report.Warnings)'"
        }
        'ok: state from older releases is read as nothing seen yet, silently'
    } finally {
        $resolved = [System.IO.Path]::GetFullPath($testRoot)
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe series fixture cleanup path' }
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
