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

$now    = Get-Date
$stored = @{ Version = '1.0'; FirstSeen = $now.AddDays(-30).ToString('o'); UpdatedAt = $now.AddDays(-30).ToString('o'); ScriptHeld = $false }

# A manifest with no git history: Get-ChillManifestDate returns $null.
$warnings = @()
$entry = Resolve-ChillEntry 'testpkg' '1.0' $null $null $stored $now -WarningVariable warnings 3>&1 |
         Where-Object { $_ -is [hashtable] }

# 1. No bogus "manifest re-pushed" warning.
$repush = @($warnings | Where-Object { "$_" -like '*re-pushed*' })
if ($repush) { throw "regression: bogus re-push warning: $($repush -join '; ')" }

# 2. UpdatedAt must stay null, not become DateTime.MinValue.
if ($null -ne $entry.UpdatedAt) { throw "regression: UpdatedAt is '$($entry.UpdatedAt)', expected null" }

# 3. FirstSeen preserved, not reset to now.
if ($entry.FirstSeen.Date -ne $now.AddDays(-30).Date) { throw "regression: FirstSeen moved to $($entry.FirstSeen)" }

'ok: null manifest date produces no warning and no MinValue UpdatedAt'

# A pinned update whose state file is missing must fall through to the skip
# warning, not throw "Cannot index into a null array" on $st['PinnedHash'].
$r = [pscustomobject]@{ Name = 'no-such-package-selfcheck'; Pin = '9.9'; Action = 'Ready' }
$warnings = @(Invoke-ChillAppUpdate $r "$env:TEMP\no-such-statedir" @{} 3>&1)
if (-not ($warnings | Where-Object { "$_" -like '*could not resolve*' })) {
    throw "regression: expected a skip warning for missing state, got: $($warnings -join '; ')"
}

'ok: pinned update with missing state warns and skips instead of throwing'

# A pin whose date could not be resolved (version aged out of manifest history)
# must warn and gate on FirstSeen, not report Held forever with no explanation.
$pinEntry = @{ Version = '2.0'; FirstSeen = $now.AddDays(-30); ScriptHeld = $false; PinnedVersion = '1.5'; PinnedDate = $null }
$pinStatus = @{ name = 'testpkg'; hold = $false }
$out      = @(Get-ChillDecision $pinEntry $pinStatus $now.AddDays(-7) $false 3>&1)
$decision = $out | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Action') }
if ($decision.Action -ne 'Ready') { throw "regression: null-date pin reports $($decision.Action), expected Ready via FirstSeen" }
if (-not ($out | Where-Object { "$_" -like '*no resolvable date*' })) {
    throw 'regression: no warning for a pin with an unresolvable date'
}

'ok: null-date pin warns and gates on first-seen instead of holding forever'

# A hold the user placed must be left alone. scoop's hold flag says an app is
# held but not by whom, so the state file's ScriptHeld is what tells the two apart.
$heldEntry  = @{ Version = '2.0'; FirstSeen = $now.AddDays(-30); ScriptHeld = $false }
$heldStatus = @{ name = 'testpkg'; hold = $true }
$decision   = Get-ChillDecision $heldEntry $heldStatus $now.AddDays(-7) $false
if ($decision.Action -ne 'ManualHold') { throw "regression: user hold reports $($decision.Action), expected ManualHold" }

# A hold this command placed is ours to release, not a manual hold.
$ourEntry = @{ Version = '2.0'; FirstSeen = $now.AddDays(-30); ScriptHeld = $true }
$decision = Get-ChillDecision $ourEntry $heldStatus $now.AddDays(-7) $false
if ($decision.Action -ne 'Ready') { throw "regression: own hold reports $($decision.Action), expected Ready" }

'ok: manual hold distinguished from a hold this command placed'

# Decision core: the age boundary, forcing, pin gating, and the auto-pin.
$cutoff = $now.AddDays(-7)
$plain  = @{ name = 'testpkg'; hold = $false }

# At exactly the cutoff the version is not yet old enough; one second older it is.
$d = Get-ChillDecision @{ FirstSeen = $cutoff; ScriptHeld = $true } $plain $cutoff $false
if ($d.Action -ne 'Held') { throw "regression: FirstSeen at cutoff reports $($d.Action), expected Held" }
$d = Get-ChillDecision @{ FirstSeen = $cutoff.AddSeconds(-1); ScriptHeld = $true } $plain $cutoff $false
if ($d.Action -ne 'Ready') { throw "regression: FirstSeen past cutoff reports $($d.Action), expected Ready" }

# --force bypasses both the age gate and a manual hold.
$d = Get-ChillDecision @{ FirstSeen = $now; ScriptHeld = $false } @{ name = 'testpkg'; hold = $true } $cutoff $true
if ($d.Action -ne 'Forced') { throw "regression: forced reports $($d.Action), expected Forced" }

# A pin gates on the pinned date even when latest is old enough on its own.
$d = Get-ChillDecision @{ FirstSeen = $now.AddDays(-30); ScriptHeld = $true; PinnedVersion = '1.5'; PinnedDate = $now.AddDays(-1) } $plain $cutoff $false
if ($d.Action -ne 'Held') { throw "regression: fresh pin reports $($d.Action), expected Held" }

# Latest moving past a script-held version auto-pins that version.
$heldStored = @{ Version = '1.0'; FirstSeen = $now.AddDays(-30).ToString('o'); ScriptHeld = $true }
$autoPin    = Resolve-ChillEntry 'testpkg' '2.0' $null $null $heldStored $now
if ($autoPin.PinnedVersion -ne '1.0') { throw "regression: auto-pin missing, PinnedVersion is '$($autoPin.PinnedVersion)'" }
if ($autoPin.Version -ne '2.0') { throw "regression: entry version is '$($autoPin.Version)', expected 2.0" }

'ok: decision core - age boundary, force, pin gating, auto-pin'

$repushedEntry = Resolve-ChillEntry 'testpkg' '1.0' $now.AddDays(-10) $null $stored $now
if (-not $repushedEntry.Repushed) { throw 'regression: re-push not detected' }
$repushDir = Join-Path ([System.IO.Path]::GetTempPath()) "chill-repush-$([guid]::NewGuid())"
try {
    Set-ChillState 'testpkg' $repushedEntry $repushDir
    $saved = Get-ChillState 'testpkg' $repushDir
    $again = Resolve-ChillEntry 'testpkg' '1.0' $now.AddDays(-10) $null $saved $now
    $d = Get-ChillDecision $again $plain $cutoff $false
    if ($d.Action -ne 'Repushed' -or $d.Ready) { throw 'regression: re-push became eligible on the next run' }
    if ((Get-ChillDecision $again $plain $cutoff $true).Action -ne 'Forced') { throw 'regression: force did not bypass re-push block' }
    $saved.ScriptHeld = $true
    $next = Resolve-ChillEntry 'testpkg' '2.0' $null $null $saved $now
    if ($next.Repushed -or $next.PinnedVersion) { throw 'regression: blocked version carried forward into a newer release' }
    $again.PinnedVersion = '0.9'
    $again.PinnedDate = $now.AddDays(-30)
    if ((Get-ChillDecision $again $plain $cutoff $false).Action -ne 'Ready') { throw 'regression: re-push blocked a different pinned version' }
    $again.PinnedVersion = '1.0'
    if ((Get-ChillDecision $again $plain $cutoff $false).Action -ne 'Repushed') { throw 'regression: pin bypassed the re-push block' }
} finally {
    $resolved = [System.IO.Path]::GetFullPath($repushDir)
    if (-not $resolved.StartsWith([System.IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { throw 'unexpected test directory' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
'ok: re-push block persists, requires force, and resets for a new version'

& {
    function Find-ChillVersionCommit { @{ Hash = 'test'; Date = $now.AddDays(-30) } }
    $legacy = @{ Version = '1.0'; FirstSeen = $now.AddDays(-30); UpdatedAt = $now.AddDays(-10) }
    foreach ($previous in @($null, $legacy)) {
        $found = Resolve-ChillEntry 'testpkg' '1.0' $now.AddDays(-10) @{} $previous $now
        if (-not $found.Repushed) { throw 'regression: history did not detect a previously observed re-push' }
    }
    $fresh = Resolve-ChillEntry 'testpkg' '1.0' $now.AddDays(-30) @{} $null $now
    if ($fresh.Repushed) { throw 'regression: unchanged manifest classified as re-pushed' }
}

& {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\scoop-chill.ps1", [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ChillReport' }, $false)
    . ([scriptblock]::Create($definition.Extent.Text))
    $output = Show-ChillReport @(
        [pscustomobject]@{ Name = 'hidden-repush'; Action = 'Repushed' },
        [pscustomobject]@{ Name = 'visible-forced'; Action = 'Forced'; Proxy = ''; Pin = '' }
    ) 6>&1 | Out-String
    if ($output -match 'hidden-repush' -or $output -notmatch 'visible-forced') { throw 'regression: report did not hide only the blocked update' }
}
'ok: history detects legacy re-pushes and the report hides blocked updates'

& {
    function Find-ChillVersionCommit { throw 'regression: cached discovery walked version history' }
    $date = $now.AddDays(-30)
    $cached = @{ Version = '1.0'; VersionHash = 'known-introduction'; FirstSeen = $date; UpdatedAt = $date; Repushed = $false }
    $unchanged = Resolve-ChillEntry 'testpkg' '1.0' $date @{} $cached $now
    if ($unchanged.Repushed) { throw 'regression: unchanged cached version blocked' }
    $changed = Resolve-ChillEntry 'testpkg' '1.0' $date.AddDays(1) @{} $cached $now
    if (-not $changed.Repushed) { throw 'regression: changed cached version not blocked' }
    $legacy = $cached.Clone()
    $legacy.Remove('Repushed')
    $legacy.UpdatedAt = $date.AddDays(1)
    $changed = Resolve-ChillEntry 'testpkg' '1.0' $date.AddDays(1) @{} $legacy $now
    if (-not $changed.Repushed) { throw 'regression: legacy cached introduction did not detect re-push' }
}
& {
    $calls = [System.Collections.Generic.List[string]]::new()
    function Find-ChillVersionCommit {
        $calls.Add('lookup')
        @{ Hash = 'introduction'; Date = $now.AddDays(-30) }
    }
    $fresh = Resolve-ChillEntry 'testpkg' '1.0' $now.AddDays(-30) @{} $null $now
    if ($calls.Count -ne 1) { throw 'regression: first discovery resolved version history more than once' }
    $calls.Clear()
    $legacy = @{ Version = '1.0'; FirstSeen = $now; UpdatedAt = $now.AddDays(-30) }
    $migrated = Resolve-ChillEntry 'testpkg' '1.0' $now.AddDays(-30) @{} $legacy $now
    $again = Resolve-ChillEntry 'testpkg' '1.0' $now.AddDays(-30) @{} $migrated $now
    if ($calls.Count -ne 1 -or $again.Repushed) { throw 'regression: missing hash was not backfilled for reuse' }
}
'ok: cached discovery performs zero history lookups; new and legacy versions resolve once'

# The proxy flag survives a state round-trip through Resolve-ChillEntry, on both
# the same-version path and the new-version path.
$proxyStored = @{ Version = '1.0'; FirstSeen = $now.AddDays(-30).ToString('o'); ScriptHeld = $false; Proxy = $true }
if (-not (Resolve-ChillEntry 'testpkg' '1.0' $null $null $proxyStored $now).Proxy) {
    throw 'regression: proxy flag lost when the version is unchanged'
}
if (-not (Resolve-ChillEntry 'testpkg' '2.0' $null $null $proxyStored $now).Proxy) {
    throw 'regression: proxy flag lost when the version moves'
}

'ok: proxy flag survives a state round-trip'

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
function Invoke-ChillAppUpdate([object]$result, [string]$dir, [hashtable]$options) { "updated $($result.Name)" }
$row = [pscustomobject]@{ Name = 'testpkg' }
$got = Invoke-ChillProxied $null { Invoke-ChillAppUpdate $row 'statedir' @{} }
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

& {
    # Real bucket history and state; Scoop installation/update operations are mocked.
    $ErrorActionPreference = 'Stop'
    . $Lib
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\scoop-chill.ps1", [ref]$null, [ref]$null)
    foreach ($name in @('Get-ChillReport', 'Show-ChillReport', 'Invoke-ChillRun', 'Confirm-ChillWrite')) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "chill-repush-flow-$([guid]::NewGuid())"
    $repo = Join-Path $testRoot 'bucket'
    $stateDir = Join-Path $testRoot 'state'
    $now = [datetime]'2026-09-20T12:00:00'
    $dryRun = $false
    $updateOptions = @{}
    $updates = [System.Collections.Generic.List[string]]::new()
    $holds = @{}
    function Get-LocalBucket { @('fixture') }
    function Find-BucketDirectory { $repo }
    function Select-CurrentVersion { '1.26.0' }
    function install_info { @{ bucket = 'fixture' } }
    function installed_apps { @('go', 'ordinary') }
    function app_status($name) {
        @{ installed = $true; outdated = $true; version = '1.26.0'; latest_version = '1.27.1'; hold = [bool]$holds[$name] }
    }
    function Set-ChillHold($name, $held) { $holds[$name] = $held; return $true }
    function Invoke-ChillScoopUpdate($name, $options) { $updates.Add($name) }
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
        $originalHash = git -C $repo rev-parse HEAD
        Write-ChillUtf8 '{"version":"1.27.1","hash":"replacement"}' "$repo\go.json"
        Commit-Fixture '2026-09-05T09:06:00+03:00' 'repush go without changing version'

        if (Test-Path $stateDir) { throw 'fixture unexpectedly has state' }
        $rows = @(Get-ChillReport (installed_apps) 7 @())
        $go = $rows | Where-Object Name -EQ 'go'
        if ($go.Action -ne 'Repushed') { throw 'Go was not blocked on first run without state' }
        $display = Show-ChillReport $rows 6>&1 | Out-String
        if ($display -match '\bgo\b' -or $display -notmatch 'ordinary') { throw 'normal report did not hide Go' }
        Invoke-ChillRun $rows
        if (($updates -join ',') -ne 'ordinary') { throw "normal flow updated unexpected apps: $updates" }
        $saved = Get-ChillState 'go' $stateDir
        if (-not $saved.Repushed -or $saved.VersionHash -ne $originalHash) { throw 're-push flag or version introduction hash not saved' }
        'ok: no prior state/hash: normal flow hides and skips Go, updates ordinary, saves block and hash'

        $updates.Clear()
        Reset-ChillCache
        Invoke-ChillRun @(Get-ChillReport (installed_apps) 7 @())
        if (($updates -join ',') -ne 'ordinary') { throw 'second run allowed re-pushed Go' }
        'ok: persisted block survives a second normal update run'

        $updates.Clear()
        $dryRun = $true
        Invoke-ChillRun @(Get-ChillReport @('go') 7 @('go'))
        if ($updates.Count) { throw 'forced dry-run called the updater' }
        $dryRun = $false
        Invoke-ChillRun @(Get-ChillReport @('go') 7 @('go'))
        if (($updates -join ',') -ne 'go' -or $holds.go) { throw 'forced update did not reach Scoop or release the hold' }
        'ok: forced dry-run does not update; forced run reaches the Scoop update boundary for Go'
    } finally {
        $resolved = [System.IO.Path]::GetFullPath($testRoot)
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe fixture cleanup path' }
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
