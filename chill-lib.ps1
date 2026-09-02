#requires -Version 5.1
# Engine for 'scoop chill': bucket git history, per-app state, and the age gate.
# The engine supports Scoop's Windows PowerShell 5.1 baseline as well as newer
# PowerShell releases.
#
# Every name here carries a Chill noun. This file is dot-sourced into a scoop
# command's scope, where an unprefixed Get-InstalledVersion or update would
# shadow scoop's own and be called by scoop's code with the wrong semantics.

#region Caches

$script:ChillManifestIndex = $null
$script:ChillLogCache      = @{}

function Reset-ChillCache {
    $script:ChillManifestIndex = $null
    $script:ChillLogCache      = @{}
}

# ponytail: ChillVersionChunkSize deadlocks near ~1000. Get-ChillVersionsAt writes
# every hash to git's stdin before reading any stdout; past the pipe buffer both
# sides block, no error, just a hang. Interleave reads before raising it that far.
$script:ChillVersionChunkSize = 64
$script:ChillLogPageSize      = 64

#endregion

#region PowerShell 5.1 compatibility

# Normalize parsed JSON to the dictionary shape used by state consumers.
function ConvertTo-ChillHashtable([object]$value) {
    if ($null -eq $value) { return $null }
    if ($value -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $value.Keys) { $table[$key] = ConvertTo-ChillHashtable $value[$key] }
        return $table
    }
    if ($value -is [pscustomobject]) {
        $table = @{}
        foreach ($property in $value.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-ChillHashtable $property.Value
        }
        return $table
    }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        return @($value | ForEach-Object { ConvertTo-ChillHashtable $_ })
    }
    return $value
}

# Quote each native argument so paths and values survive a single command-line
# string unchanged on every supported runtime.
function ConvertTo-ChillNativeArgument([string]$value) {
    if ($value.Length -gt 0 -and $value -notmatch '[\s"]') { return $value }
    $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# Keep state files and temporary manifests in BOM-less UTF-8 on every runtime.
function Write-ChillUtf8([string]$content, [string]$path) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $encoding)
}

#endregion

#region Bucket history

# Manifests live in <bucket>\bucket when that dir exists, else the bucket root.
function Get-ChillManifestIndex {
    if ($script:ChillManifestIndex) { return $script:ChillManifestIndex }
    $idx = @{}
    foreach ($bucket in Get-LocalBucket) {
        $root = Find-BucketDirectory $bucket -Root
        if (-not (Test-Path "$root\.git")) { continue }
        $manifestDir = Find-BucketDirectory $bucket
        foreach ($m in Get-ChildItem $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            $name = $m.BaseName
            if (-not $idx.ContainsKey($name)) { $idx[$name] = @{} }
            $idx[$name][$bucket] = @{
                ManifestPath = $m.FullName
                BucketRoot   = $root
                # Forward slashes so `git show <hash>:<RelPath>` resolves the tree path.
                RelPath      = $m.FullName.Substring($root.Length + 1).Replace('\', '/')
            }
        }
    }
    $script:ChillManifestIndex = $idx
    return $idx
}

function Find-ChillManifest([string]$Name) {
    $idx = Get-ChillManifestIndex
    if (-not $idx.ContainsKey($Name)) { return $null }
    $byBucket = $idx[$Name]
    $installed = (install_info $Name (Select-CurrentVersion -AppName $Name) $false).bucket
    if ($installed -and $byBucket.ContainsKey($installed)) { return $byBucket[$installed] }
    # Select-Object, not [0]: a lone key is a bare string, whose [0] is a character.
    return $byBucket[($byBucket.Keys | Sort-Object | Select-Object -First 1)]
}

function ConvertTo-ChillDate([object]$value) {
    if ($null -eq $value)      { return $null }
    if ($value -is [datetime]) { return $value }
    try { [datetime]::Parse($value, [cultureinfo]::InvariantCulture) } catch { $null }
}

function ConvertFrom-ChillDate([object]$value) {
    if ($value -is [datetime]) { return $value.ToString('o') }
    return $value
}

# Read each commit's `version` field with one `git cat-file --batch`. Records are
# <oid> blob <size>\n<content>\n; parsed by byte offset so multi-byte UTF-8 in a
# manifest cannot desync the record boundaries. Returns hash -> version.
function Get-ChillVersionsAt([string]$root, [string]$relPath, [System.Collections.Generic.List[string]]$hashes) {
    $result = @{}
    if (-not $hashes -or $hashes.Count -eq 0) { return $result }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.Arguments = (@('-C', $root, 'cat-file', '--batch') | ForEach-Object { ConvertTo-ChillNativeArgument $_ }) -join ' '
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute        = $false
    $psi.WorkingDirectory       = $root

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        # A sacrificial first query absorbs any BOM emitted by the framework's
        # redirected input stream, keeping real object ids valid and aligned
        # with the responses parsed below.
        $queries = "chill-invalid-object`n" + (($hashes | ForEach-Object { "${_}:$relPath" }) -join "`n") + "`n"
        $queryBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($queries)
        $proc.StandardInput.BaseStream.Write($queryBytes, 0, $queryBytes.Length)
        $proc.StandardInput.Close()

        $ms = [System.IO.MemoryStream]::new()
        $proc.StandardOutput.BaseStream.CopyTo($ms)
        $proc.WaitForExit()
        $data = $ms.ToArray()
    } finally {
        $proc.Dispose()
    }

    $rx = [regex]'"version"\s*:\s*"([^"]*)"'
    $i  = 0
    # Skip the sacrificial query's response before mapping hashes to results.
    while ($i -lt $data.Length -and $data[$i] -ne 10) { $i++ }
    if ($i -lt $data.Length) { $i++ }
    foreach ($h in $hashes) {
        if ($i -ge $data.Length) { $result[$h] = $null; continue }
        $lineStart = $i
        while ($i -lt $data.Length -and $data[$i] -ne 10) { $i++ }
        $header = [System.Text.Encoding]::ASCII.GetString($data, $lineStart, $i - $lineStart)
        $i++  # skip LF
        $parts = $header -split ' '
        if ($parts.Length -lt 3 -or $parts[1] -ne 'blob') { $result[$h] = $null; continue }
        $size    = [int]$parts[2]
        $content = [System.Text.Encoding]::UTF8.GetString($data, $i, $size)
        $i += $size
        if ($i -lt $data.Length -and $data[$i] -eq 10) { $i++ }  # trailing LF
        $m = $rx.Match($content)
        $result[$h] = if ($m.Success) { $m.Groups[1].Value } else { $null }
    }
    return $result
}

# Commit log, newest first, memoized per manifest. Vers fills lazily via
# Get-ChillVersionAt, so a shallow query on a deep history reads only the blobs
# it needs.
function Get-ChillLog([hashtable]$file) {
    if (-not $file) { return $null }
    $key = "$($file.BucketRoot)|$($file.RelPath)"
    if ($script:ChillLogCache.ContainsKey($key)) { return $script:ChillLogCache[$key] }
    $log = @{
        File     = $file
        Hashes   = [System.Collections.Generic.List[string]]::new()
        Dates    = @{}
        Vers     = @{}
        Complete = $false
    }
    $script:ChillLogCache[$key] = $log
    Expand-ChillLog $log 1
    return $log
}

# Page commits in until $count are known or history runs out. A pathspec makes git
# walk every commit to filter, so --max-count, which ends the walk as soon as it
# has enough, is what keeps a near-HEAD query off the full history of a big bucket.
function Expand-ChillLog([hashtable]$log, [int]$count) {
    while (-not $log.Complete -and $log.Hashes.Count -lt $count) {
        $page  = [Math]::Max($count - $log.Hashes.Count, $script:ChillLogPageSize)
        $lines = @(git -C $log.File.BucketRoot log --format='%H %aI' --skip=$($log.Hashes.Count) --max-count=$page -- $log.File.RelPath 2>$null)
        foreach ($line in $lines) {
            $h, $d = $line -split ' ', 2
            $log.Hashes.Add($h); $log.Dates[$h] = $d
        }
        if ($lines.Count -lt $page) { $log.Complete = $true }
    }
}

# On a miss, batches the next chunk of hashes: one git process per chunk, not per commit.
function Get-ChillVersionAt([hashtable]$file, [hashtable]$log, [int]$index) {
    $h = $log.Hashes[$index]
    if (-not $log.Vers.ContainsKey($h)) {
        $chunk = [System.Collections.Generic.List[string]]::new()
        $end   = [Math]::Min($index + $script:ChillVersionChunkSize, $log.Hashes.Count)
        for ($j = $index; $j -lt $end; $j++) {
            if (-not $log.Vers.ContainsKey($log.Hashes[$j])) { $chunk.Add($log.Hashes[$j]) }
        }
        foreach ($kv in (Get-ChillVersionsAt $file.BucketRoot $file.RelPath $chunk).GetEnumerator()) {
            $log.Vers[$kv.Key] = $kv.Value
        }
    }
    return $log.Vers[$h]
}

# Earliest commit of the most recent run in which the manifest carried $Version.
# Walks newest-first and stops once it passes that run's lower bound.
function Find-ChillVersionCommit([string]$Version, [hashtable]$file) {
    if (-not $Version -or -not $file) { return $null }
    $log = Get-ChillLog $file
    if (-not $log) { return $null }
    $intro = $null
    for ($i = 0; ; $i++) {
        Expand-ChillLog $log ($i + 1)
        if ($i -ge $log.Hashes.Count) { break }
        if ((Get-ChillVersionAt $file $log $i) -eq $Version) {
            $h = $log.Hashes[$i]
            $intro = @{ Hash = $h; Date = (ConvertTo-ChillDate $log.Dates[$h]) }
        } elseif ($intro) {
            break
        }
    }
    return $intro
}

function Get-ChillManifestDate([hashtable]$file) {
    if (-not $file) { return $null }
    ConvertTo-ChillDate (git -C $file.BucketRoot log -1 --format='%aI' -- $file.RelPath 2>$null)
}

# The version one step newer than $installed in the manifest's history, or $null
# when $installed is already the newest or is absent from the log. Commit order,
# not version parsing: bucket versions are not all semver (llama.cpp ships b10214).
function Find-ChillNextVersion([hashtable]$file, [string]$installed) {
    $log = Get-ChillLog $file
    if (-not $log) { return $null }
    $newer = $null
    $seen  = [System.Collections.Generic.HashSet[string]]::new()
    for ($i = 0; ; $i++) {
        Expand-ChillLog $log ($i + 1)
        if ($i -ge $log.Hashes.Count) { return $null }  # installed never found
        $v = Get-ChillVersionAt $file $log $i
        if (-not $v -or -not $seen.Add($v)) { continue }
        if ($v -eq $installed) { return $newer }
        $newer = $v
    }
}

#endregion

#region Bucket reset

# Buckets whose working tree has drifted from HEAD, which is what stops a
# refresh: git refuses to pull over a modified manifest, and every version
# lookup here then reads history that no longer matches what is on disk.
function Get-ChillDirtyBucket([string[]]$named) {
    $names = if ($named) { $named } else { @(Get-LocalBucket) }
    foreach ($bucket in $names) {
        $root = Find-BucketDirectory $bucket -Root
        if (-not (Test-Path "$root\.git")) {
            warn "'$bucket' isn't a git repository; skipped."
            continue
        }
        # Porcelain v1 is a stable format, one line per changed path.
        $changes = @(git -C $root status --porcelain)
        if ($changes.Count -eq 0) { continue }
        [pscustomobject]@{
            Bucket  = $bucket
            Root    = $root
            Changes = $changes
        }
    }
}

# Discard those changes: reset tracked files to HEAD, delete untracked ones.
# Ignored files are left alone - 'clean -fd' without -x, as in the script this
# came from.
function Reset-GitBucket([string]$root) {
    git -C $root reset --hard HEAD | Out-Null
    git -C $root clean -fd | Out-Null
    return $LASTEXITCODE -eq 0
}

#endregion

#region State

function Get-ChillStateDir {
    "$scoopdir\persist\scoop-chill"
}

function Get-ChillSettings([string]$dir) {
    Read-ChillJson (Join-Path $dir '_scoop_chill.json') @{}
}

# Merge one shared setting into the persistent file. Proxy and refresh writes can
# happen independently without replacing one another.
function Set-ChillSetting([string]$name, [object]$value, [string]$dir) {
    New-Item $dir -ItemType Directory -Force | Out-Null
    $settings = Get-ChillSettings $dir
    $settings[$name] = $value
    Write-ChillJson $settings (Join-Path $dir '_scoop_chill.json')
}

function Write-ChillJson([object]$content, [string]$path) {
    $tmp = "$path.tmp"
    # Stop, not continue: a path the filesystem rejects used to leave the caller
    # announcing a write that never landed. A name with a colon is worse than a
    # plain failure, since Set-Content writes it to an alternate data stream and
    # only Move-Item complains.
    Write-ChillUtf8 ($content | ConvertTo-Json -Depth 5) $tmp
    Move-Item $tmp $path -Force -ErrorAction Stop
}

function Read-ChillJson([string]$path, [object]$fallback) {
    if (Test-Path $path) { try { ConvertTo-ChillHashtable (Get-Content $path -Raw | ConvertFrom-Json) } catch { $fallback } } else { $fallback }
}

function Get-ChillState([string]$name, [string]$dir) {
    Read-ChillJson (Join-Path $dir "$name.json") $null
}

function Set-ChillState([string]$name, [hashtable]$entry, [string]$dir) {
    New-Item $dir -ItemType Directory -Force | Out-Null
    Write-ChillJson @{
        Version       = $entry.Version
        VersionHash   = $entry['VersionHash']
        FirstSeen     = ConvertFrom-ChillDate $entry.FirstSeen
        UpdatedAt     = ConvertFrom-ChillDate $entry.UpdatedAt
        ScriptHeld    = $entry.ScriptHeld
        Proxy         = [bool]$entry['Proxy']
        PinnedVersion = $entry['PinnedVersion']
        PinnedHash    = $entry['PinnedHash']
        PinnedDate    = ConvertFrom-ChillDate $entry['PinnedDate']
    } (Join-Path $dir "$name.json")
}

# Read-modify-write of one state field, for the pin and proxy subcommands, which
# edit state for apps that may have no entry yet.
function Update-ChillState([string]$name, [string]$dir, [hashtable]$fields) {
    $st = Get-ChillState $name $dir
    if (-not $st) { $st = @{ Version = $null; VersionHash = $null; FirstSeen = $null; UpdatedAt = $null; ScriptHeld = $false } }
    foreach ($kv in $fields.GetEnumerator()) { $st[$kv.Key] = $kv.Value }
    Set-ChillState $name $st $dir
    return $st
}

function Set-ChillPin([string]$name, [string]$version, [string]$dir) {
    $file = Find-ChillManifest $name
    if (-not $file) { Write-Warning "$($name): no bucket manifest found; cannot pin"; return }
    $commit = Find-ChillVersionCommit $version $file
    if (-not $commit) { Write-Warning "$($name): version $version not found in git history; pin not set"; return }
    Update-ChillState $name $dir @{
        PinnedVersion = $version
        PinnedHash    = $commit.Hash
        PinnedDate    = $commit.Date
    } | Out-Null
}

function Clear-ChillPin([string]$name, [string]$dir) {
    if (-not (Get-ChillState $name $dir)) { return }
    Update-ChillState $name $dir @{ PinnedVersion = $null; PinnedHash = $null; PinnedDate = $null } | Out-Null
}

# Version to pin for a bare `chill pin <app>`: one step newer than what is
# installed. Warns rather than returning silently, since the caller named an app.
function Resolve-ChillNextPin([string]$name) {
    $installed = Select-CurrentVersion -AppName $name
    if (-not $installed) { Write-Warning "$($name): not installed, cannot pin to next version"; return $null }
    $file = Find-ChillManifest $name
    if (-not $file) { Write-Warning "$($name): no bucket manifest found"; return $null }
    $next = Find-ChillNextVersion $file $installed
    if (-not $next) { Write-Warning "$($name): already at the newest version in bucket history ($installed)" }
    return $next
}

#endregion

#region Decisions

# Merge stored state with current bucket facts into a full entry.
function Resolve-ChillEntry([string]$name, [string]$latest, [nullable[datetime]]$manifestDate, [hashtable]$file, [hashtable]$stored, [datetime]$now) {
    if ($stored -and $stored.Version -eq $latest) {
        $entry = @{
            Version       = $stored.Version
            VersionHash   = $stored['VersionHash']
            FirstSeen     = ConvertTo-ChillDate $stored.FirstSeen
            UpdatedAt     = ConvertTo-ChillDate $stored.UpdatedAt
            ScriptHeld    = [bool]$stored['ScriptHeld']
            Proxy         = [bool]$stored['Proxy']
            PinnedVersion = $stored['PinnedVersion']
            PinnedHash    = $stored['PinnedHash']
            PinnedDate    = ConvertTo-ChillDate $stored['PinnedDate']
        }
        if ($manifestDate -and $entry.UpdatedAt -and $manifestDate -ne $entry.UpdatedAt) {
            $newCommit = Find-ChillVersionCommit $latest $file
            $oldHash   = $entry['VersionHash']
            $hashNote  = if ($oldHash -and $newCommit.Hash -and $oldHash -ne $newCommit.Hash) {
                " (hash $($oldHash.Substring(0,7)) -> $($newCommit.Hash.Substring(0,7)))"
            } else { '' }
            Write-Warning "${name}: manifest re-pushed for $latest (was $($entry.UpdatedAt.ToString('yyyy-MM-dd HH:mm')), now $($manifestDate.ToString('yyyy-MM-dd HH:mm')))$hashNote"
            if ($newCommit.Hash) { $entry['VersionHash'] = $newCommit.Hash }
        }
        $entry.UpdatedAt = $manifestDate
    } else {
        $commit = Find-ChillVersionCommit $latest $file
        $entry  = @{
            Version       = $latest
            VersionHash   = $commit.Hash
            FirstSeen     = if ($commit.Date) { $commit.Date } else { $now }
            UpdatedAt     = $manifestDate
            ScriptHeld    = if ($stored) { [bool]$stored['ScriptHeld'] } else { $false }
            Proxy         = if ($stored) { [bool]$stored['Proxy'] } else { $false }
            PinnedVersion = $null
            PinnedHash    = $null
            PinnedDate    = $null
        }
        if ($stored -and $stored['PinnedVersion']) {
            $entry['PinnedVersion'] = $stored['PinnedVersion']
            $entry['PinnedHash']    = $stored['PinnedHash']
            $entry['PinnedDate']    = ConvertTo-ChillDate $stored['PinnedDate']
        } elseif ($stored -and $stored['ScriptHeld'] -and $stored['Version']) {
            # Latest moved past a version we were holding: pin to that version so
            # the upgrade path goes through it first.
            $pinCommit = Find-ChillVersionCommit $stored['Version'] $file
            $entry['PinnedVersion'] = $stored['Version']
            $entry['PinnedHash']    = $pinCommit.Hash
            $entry['PinnedDate']    = $pinCommit.Date
        }
    }
    if (-not $entry.FirstSeen) { $entry.FirstSeen = $now }
    return $entry
}

# A pin gates on the pinned version's date; everything else on latest's first-seen.
# $status is scoop's own app_status hashtable, whose .hold is a real boolean,
# rather than the 'Held package' text scoop status joins into its Info column.
function Get-ChillDecision([hashtable]$entry, [hashtable]$status, [datetime]$cutoff, [bool]$forced) {
    $manualHold = [bool]$status.hold -and -not $entry.ScriptHeld
    $gate       = if ($entry['PinnedVersion']) { $entry['PinnedDate'] } else { $entry.FirstSeen }
    if ($entry['PinnedVersion'] -and -not $gate) {
        # The auto-pin path can store a pin whose version has aged out of the
        # manifest history; a null date would otherwise hold forever, silently.
        Write-Warning "$($status.name): pinned $($entry['PinnedVersion']) has no resolvable date; gating on first-seen"
        $gate = $entry.FirstSeen
    }
    $ready = $forced -or ($gate -and $gate -lt $cutoff)

    $action = if ($manualHold -and -not $forced) { 'ManualHold' }
              elseif ($ready)                    { if ($forced) { 'Forced' } else { 'Ready' } }
              else                               { 'Held' }

    return @{ Action = $action; ManualHold = $manualHold; Ready = $ready; Gate = $gate }
}

#endregion

#region Execution

# scoop's own hold, written directly: scoop-hold.ps1 is a script, so invoking it
# means a subprocess per app for a one-field edit of install.json.
function Set-ChillHold([string]$name, [bool]$held) {
    $version = Select-CurrentVersion -AppName $name
    $dir     = versiondir $name $version $false
    $json    = install_info $name $version $false
    if (-not $json) { Write-Warning "$($name): no install.json; cannot change hold"; return $false }
    # install_info parses to a PSCustomObject, which cannot take a 'hold'
    # property it does not already have, and which save_install_info reads as a
    # hashtable. scoop-hold.ps1 converts the same way before writing.
    $install = @{}
    $json | Get-Member -MemberType Properties | ForEach-Object { $install.Add($_.Name, $json.($_.Name)) }
    $install.hold = $held
    save_install_info $install $dir
    # Report what landed, not what was attempted: a hold that failed but claimed
    # success left the state file saying this command holds an app it does not,
    # so nothing would ever hold it again.
    $written = (install_info $name $version $false).hold
    if ($written -ne $held) {
        Write-Warning "$($name): hold was not written; install.json still reads $(if ($written) { 'held' } else { 'not held' })"
        return $false
    }
    return $true
}

# Run $action with scoop routed through $url. scoop reads the proxy from a
# process-global static that Invoke-Download and the aria2 option builder both
# consult, so this needs no config file write: nothing can leak past the process,
# and there is no need to batch proxied apps into a separate pass.
# setup_proxy is scoop's own parser, reused so the credential syntax stays
# identical; the in-memory config is restored and never written to disk.
# scoop's proxy config is '[username:password@]host:port', with no scheme:
# setup_proxy builds the url itself as "http://$address". A stored 'http://host:port'
# would become 'http://http//host:port', which routes nowhere and hands aria2 an
# --all-proxy of 'http'. Accept the url a person would type, and strip it.
function ConvertTo-ChillProxyAddress([string]$url) {
    return $url -replace '^[a-z][a-z0-9+.-]*://', ''
}

function Invoke-ChillProxied([string]$url, [scriptblock]$action) {
    if (-not $url) { return & $action }
    $url = ConvertTo-ChillProxyAddress $url
    $savedProxy  = [Net.WebRequest]::DefaultWebProxy
    $savedConfig = $scoopConfig.proxy
    try {
        if ($null -eq $scoopConfig.proxy) {
            $scoopConfig | Add-Member -MemberType NoteProperty -Name 'proxy' -Value $url -Force
        } else {
            $scoopConfig.proxy = $url
        }
        setup_proxy
        & $action
    } finally {
        $scoopConfig.proxy = $savedConfig
        [Net.WebRequest]::DefaultWebProxy = $savedProxy
    }
}

# Swap the bucket manifest to a pinned commit, update, then restore it. Refuses
# when the manifest already differs from HEAD, so the restoring checkout cannot
# discard a pre-existing local edit.
function Invoke-ChillPinnedUpdate([string]$name, [string]$pinnedHash, [hashtable]$file, [hashtable]$options) {
    $dirty = git -C $file.BucketRoot status --porcelain -- $file.RelPath 2>$null
    if ($dirty) {
        Write-Warning "$($name): bucket manifest $($file.RelPath) has uncommitted changes; skipping pinned update to avoid clobbering them"
        return $false
    }
    $pinned = git -C $file.BucketRoot show "${pinnedHash}:$($file.RelPath)" 2>$null
    if (-not $pinned) {
        Write-Warning "$($name): could not retrieve manifest at $pinnedHash from git"
        return $false
    }
    try {
        $before = Select-CurrentVersion -AppName $name
        Write-ChillUtf8 ($pinned -join [Environment]::NewLine) $file.ManifestPath
        Invoke-ChillScoopUpdate $name $options
        # scoop's update reports nothing when it skips an app (e.g. still
        # running), so the installed version is the only reliable success signal.
        # Keep the pin otherwise, or the retry is lost.
        if ((Select-CurrentVersion -AppName $name) -eq $before) {
            Write-Warning "$($name): update did not apply, keeping pin"
            return $false
        }
        return $true
    } finally {
        git -C $file.BucketRoot checkout HEAD -- $file.RelPath 2>$null | Out-Null
        # The restored manifest is a different blob on disk; drop the memoized log.
        Reset-ChillCache
    }
}

# scoop's update, in this process. $options carries the flags scoop's own
# 'update' takes, so a caller can pass them through without a subprocess.
function Invoke-ChillScoopUpdate([string]$name, [hashtable]$options) {
    update $name $false $options.Quiet $options.Independent $options.Suggested $options.UseCache $options.CheckHash
}

# A forced app still needs unholding here; ready apps were unheld in the
# decision pass.
function Invoke-ChillAppUpdate([object]$result, [string]$dir, [hashtable]$options) {
    if ($result.Action -eq 'Forced') { Set-ChillHold $result.Name $false | Out-Null }
    if ($result.Pin -eq '') {
        Invoke-ChillScoopUpdate $result.Name $options
        return
    }
    $file = Find-ChillManifest $result.Name
    $st   = Get-ChillState $result.Name $dir
    $hash = if ($st) { $st['PinnedHash'] } else { $null }
    if (-not $hash -and $file) { $hash = (Find-ChillVersionCommit $result.Pin $file).Hash }
    # $st gates too: the success path below indexes it to clear the pin.
    if (-not $st -or -not $hash -or -not $file) {
        Write-Warning "$($result.Name): could not resolve pinned $($result.Pin) in git history, skipping"
        return
    }
    if (Invoke-ChillPinnedUpdate $result.Name $hash $file $options) {
        Clear-ChillPin $result.Name $dir
    }
}

#endregion
