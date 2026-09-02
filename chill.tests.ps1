#requires -Version 5.1
# Self-checks for the chill engine. These exercise the pure decision core only,
# so they load chill-lib.ps1 on its own, without scoop's libs or a scoop install.
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
