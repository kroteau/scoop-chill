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
$script:ChillLogFirstPageSize = 4

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

# Read each commit's top-level `version` with one `git cat-file --batch`. Records are
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

    $i = 0
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
        # Parsed as Scoop parses it, which reads the top-level key: a pattern
        # match takes the first "version" anywhere, so a nested one placed
        # first passed a new version off as an aged one. A manifest Scoop could
        # not parse has no version.
        try {
            $version = ($content.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop).version
            $result[$h] = if ($version -is [string]) { $version } else { $null }
        } catch {
            $result[$h] = $null
        }
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
        PageSize = 0
    }
    $script:ChillLogCache[$key] = $log
    Expand-ChillLog $log 1
    return $log
}

# Page commits in until $count are known or history runs out. A pathspec makes git
# walk every commit to filter, so --max-count, which ends the walk as soon as it
# has enough, is what keeps a near-HEAD query off the full history of a big bucket.
# Asking for more commits than the file has walks that whole history anyway, so
# pages start small and double: most lookups end a few commits below HEAD.
function Expand-ChillLog([hashtable]$log, [int]$count) {
    while (-not $log.Complete -and $log.Hashes.Count -lt $count) {
        $log.PageSize = if ($log.PageSize) { 2 * $log.PageSize } else { $script:ChillLogFirstPageSize }
        $page  = [Math]::Max($count - $log.Hashes.Count, $log.PageSize)
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

# The most recent run of commits in which the manifest carried $Version, shaped
# as Get-ChillNewerVersions returns them. Walks newest-first and stops once it
# passes that run's lower bound.
function Find-ChillVersionRun([string]$Version, [hashtable]$file) {
    if (-not $Version -or -not $file) { return $null }
    $log = Get-ChillLog $file
    if (-not $log) { return $null }
    $run = $null
    for ($i = 0; ; $i++) {
        Expand-ChillLog $log ($i + 1)
        if ($i -ge $log.Hashes.Count) { break }
        if ((Get-ChillVersionAt $file $log $i) -eq $Version) {
            $h      = $log.Hashes[$i]
            $commit = @{ Hash = $h; Date = (ConvertTo-ChillDate $log.Dates[$h]) }
            if (-not $run) { $run = @{ Version = $Version; Newest = $commit; Commits = [System.Collections.Generic.List[hashtable]]::new() } }
            $run.Original = $commit
            $run.Commits.Add($commit)
        } elseif ($run) {
            break
        }
    }
    return $run
}

# Each version newer than $installed, newest first, from its most recent run of
# commits: Original is the run's first commit and Newest its last, so a run of
# more than one is a version rewritten after its release. Commit order, not
# version parsing: bucket versions are not all semver (llama.cpp ships b10214).
# With $installed absent from history nothing orders it, so only latest is
# offered: any older entry could be a downgrade.
function Get-ChillNewerVersions([hashtable]$file, [string]$installed) {
    $log = Get-ChillLog $file
    if (-not $log) { return }
    $versions = [System.Collections.Generic.List[hashtable]]::new()
    $seen     = [System.Collections.Generic.HashSet[string]]::new()
    $run      = $null
    for ($i = 0; ; $i++) {
        Expand-ChillLog $log ($i + 1)
        if ($i -ge $log.Hashes.Count) { return $versions | Select-Object -First 1 }
        $v      = Get-ChillVersionAt $file $log $i
        $h      = $log.Hashes[$i]
        $commit = @{ Hash = $h; Date = (ConvertTo-ChillDate $log.Dates[$h]) }
        if ($run -and $v -eq $run.Version) { $run.Original = $commit; $run.Commits.Add($commit); continue }
        if ($v -eq $installed) { return $versions }
        $run = $null
        if (-not $v -or -not $seen.Add($v)) { continue }
        $run = @{ Version = $v; Original = $commit; Newest = $commit; Commits = [System.Collections.Generic.List[hashtable]]::new() }
        $run.Commits.Add($commit)
        $versions.Add($run)
    }
}

# The manifest fields Scoop's schema has deciding what is downloaded, where it
# goes, what it links or sets, and what runs. Description, notes, checkver,
# autoupdate and the like change nothing that is installed.
$script:ChillInstallFieldNames = @(
    'url', 'hash', 'extract_dir', 'extract_to', 'innosetup', 'depends',
    'bin', 'shortcuts', 'persist', 'psmodule', 'env_add_path', 'env_set',
    'installer', 'uninstaller', 'pre_install', 'post_install', 'pre_uninstall', 'post_uninstall'
)

# What a manifest installs: each install field, top level and per architecture,
# keyed by its path ('architecture.64bit.url') and rendered as JSON to compare.
function Get-ChillInstallFields([object]$manifest) {
    $fields = @{}
    $scopes = @(@{ Prefix = ''; Value = $manifest })
    if ($manifest.architecture) {
        foreach ($arch in @($manifest.architecture.PSObject.Properties)) {
            $scopes += @{ Prefix = "architecture.$($arch.Name)."; Value = $arch.Value }
        }
    }
    foreach ($scope in $scopes) {
        foreach ($name in $script:ChillInstallFieldNames) {
            $value = $scope.Value.$name
            if ($null -ne $value) { $fields["$($scope.Prefix)$name"] = ConvertTo-Json -InputObject $value -Compress -Depth 20 }
        }
    }
    return $fields
}

# The first commit in $run, a version's run of commits, that changed what its
# release installs, with Fields naming what changed; $null when every commit
# kept it.
function Find-ChillInstallRewrite([hashtable]$file, [hashtable]$run) {
    if ($run.Commits.Count -lt 2) { return $null }
    $installs = @{}
    foreach ($commit in $run.Commits) {
        $json = git -C $file.BucketRoot show "$($commit.Hash):$($file.RelPath)" 2>$null
        $installs[$commit.Hash] = Get-ChillInstallFields ($json -join "`n" | ConvertFrom-Json)
    }
    $released = $installs[$run.Original.Hash]
    # Commits are newest first, so walk them oldest first to find the first change.
    for ($i = $run.Commits.Count - 2; $i -ge 0; $i--) {
        $current = $installs[$run.Commits[$i].Hash]
        $changed = @(@($released.Keys) + @($current.Keys) | Sort-Object -Unique | Where-Object { $released[$_] -cne $current[$_] })
        if ($changed) { return @{ Hash = $run.Commits[$i].Hash; Date = $run.Commits[$i].Date; Fields = $changed } }
    }
    return $null
}

# How many versions in history are newer than $version, or $null when $version
# is not in history at all. Distinct versions, counted from the newest run of
# each, so a rewrite does not count twice.
function Measure-ChillVersionsBehind([hashtable]$file, [string]$version) {
    $log = Get-ChillLog $file
    if (-not $log) { return $null }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    for ($i = 0; ; $i++) {
        Expand-ChillLog $log ($i + 1)
        if ($i -ge $log.Hashes.Count) { return $null }
        $v = Get-ChillVersionAt $file $log $i
        if ($v -eq $version) { return $seen.Count }
        if ($v) { $seen.Add($v) | Out-Null }
    }
}

# The newest version past the age gate, judged by when chill first saw it;
# failing that, the oldest, which is the next to pass it.
function Select-ChillUpdateTarget([object[]]$versions, [datetime]$cutoff) {
    $aged = @($versions | Where-Object { $_.Seen -and $_.Seen -lt $cutoff })
    if ($aged) { return $aged[0] }
    return $versions | Select-Object -Last 1
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

# Buckets a refresh begun at $since left behind. scoop's sync runs 'git pull'
# and ignores its failure, so check each bucket that tracks a remote: the fetch
# must have written FETCH_HEAD since then, and its result must be in HEAD. A
# failed fetch still rewrites FETCH_HEAD, but leaves it empty.
function Get-ChillUnsyncedBucket([datetime]$since) {
    foreach ($bucket in Get-LocalBucket) {
        $root = Find-BucketDirectory $bucket -Root
        if (-not (Test-Path "$root\.git")) { continue }
        $upstream = git -C $root rev-parse --verify -q '@{u}' 2>$null
        if (-not $upstream) { continue }
        $fetchHead = Get-Item (Join-Path $root (git -C $root rev-parse --git-path FETCH_HEAD)) -ErrorAction SilentlyContinue
        $isFetched = $fetchHead -and $fetchHead.LastWriteTime -ge $since -and $fetchHead.Length -gt 0
        git -C $root merge-base --is-ancestor $upstream HEAD 2>$null
        $isMerged = $LASTEXITCODE -eq 0
        if ($isFetched -and $isMerged) { continue }
        [pscustomobject]@{
            Bucket  = $bucket
            Reason  = if (-not $isFetched) { 'could not fetch' } else { 'could not merge' }
            IsDirty = [bool](git -C $root status --porcelain)
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
    $seen = @{}
    if ($entry['Seen'] -is [System.Collections.IDictionary]) {
        foreach ($kv in $entry['Seen'].GetEnumerator()) { $seen[$kv.Key] = ConvertFrom-ChillDate $kv.Value }
    }
    Write-ChillJson @{
        ScriptHeld = [bool]$entry['ScriptHeld']
        Proxy      = [bool]$entry['Proxy']
        Seen       = $seen
    } (Join-Path $dir "$name.json")
}

# Read-modify-write of one state field, for holds and the proxy subcommand, which
# edit state for apps that may have no entry yet.
function Update-ChillState([string]$name, [string]$dir, [hashtable]$fields) {
    $st = Get-ChillState $name $dir
    if (-not $st) { $st = @{ ScriptHeld = $false } }
    foreach ($kv in $fields.GetEnumerator()) { $st[$kv.Key] = $kv.Value }
    Set-ChillState $name $st $dir
    return $st
}

#endregion

#region Decisions

function ConvertTo-ChillTargets([string[]]$arguments) {
    $seen = @{}
    foreach ($argument in $arguments) {
        if ($argument -notmatch '^(?<name>[^@\s/\\:]+)(?:@(?<version>[^@\s/\\:]+))?$' -or $argument.Contains('*')) {
            throw "Invalid app target '$argument'; use <app> or <app>@<version>."
        }
        $name    = $Matches.name
        $version = $Matches.version
        if ($seen.ContainsKey($name)) { throw "App '$name' was specified more than once." }
        $seen[$name] = $true
        [pscustomobject]@{ Name = $name; Version = $version; Argument = $argument }
    }
}

# The stored state a decision reads, defaulted for an app that has none. Seen
# maps each version to when chill first saw it; an unreadable date counts as
# never seen, which only delays that version.
function ConvertTo-ChillEntry([hashtable]$stored) {
    if (-not $stored) { $stored = @{} }
    $seen = @{}
    if ($stored['Seen'] -is [System.Collections.IDictionary]) {
        foreach ($kv in $stored['Seen'].GetEnumerator()) {
            $date = ConvertTo-ChillDate $kv.Value
            if ($date) { $seen[$kv.Key] = $date }
        }
    }
    @{
        ScriptHeld = [bool]$stored['ScriptHeld']
        Proxy      = [bool]$stored['Proxy']
        Seen       = $seen
    }
}

# When chill first saw each of $versions: the recorded date, or $at for a
# version it has not seen before. Never a git date, which a commit's author
# sets and can backdate. Dates covers $versions alone, so a version no longer
# in question drops out of state on the next write; Unrecorded lists the
# versions $at was given to.
function Get-ChillFirstSeen([hashtable]$recorded, [string[]]$versions, [datetime]$at) {
    $dates      = @{}
    $unrecorded = [System.Collections.Generic.List[string]]::new()
    foreach ($version in $versions) {
        if (-not $version -or $dates.ContainsKey($version)) { continue }
        if ($recorded -and $recorded.ContainsKey($version)) {
            $dates[$version] = $recorded[$version]
        } else {
            $dates[$version] = $at
            $unrecorded.Add($version)
        }
    }
    return @{ Dates = $dates; Unrecorded = @($unrecorded) }
}

# Gates on when chill first saw the update target.
# $status is scoop's own app_status hashtable, whose .hold is a real boolean,
# rather than the 'Held package' text scoop status joins into its Info column.
function Get-ChillDecision([hashtable]$entry, [hashtable]$status, [datetime]$cutoff, [bool]$forced) {
    $manualHold = [bool]$status.hold -and -not $entry.ScriptHeld
    $gate       = $entry['TargetDate']
    $ready =$forced -or ($gate -and $gate -lt $cutoff)

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

# Set scoop's hold and record that this command owns it, or no longer does. The
# record is written only once the hold has landed.
function Set-ChillOwnedHold([string]$name, [bool]$held, [string]$dir) {
    if (Set-ChillHold $name $held) { Update-ChillState $name $dir @{ ScriptHeld = $held } | Out-Null }
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

# Swap the bucket manifest to a historical commit, update, then restore it.
# Refuses when the manifest already differs from HEAD, so the restoring checkout
# cannot discard a pre-existing local edit.
function Invoke-ChillHistoricalUpdate([string]$name, [string]$commitHash, [hashtable]$file, [hashtable]$options) {
    $dirty = git -C $file.BucketRoot status --porcelain -- $file.RelPath 2>$null
    if ($dirty) {
        Write-Warning "$($name): bucket manifest $($file.RelPath) has uncommitted changes; skipping historical update to avoid clobbering them"
        return $false
    }
    $historical = git -C $file.BucketRoot show "${commitHash}:$($file.RelPath)" 2>$null
    if (-not $historical) {
        Write-Warning "$($name): could not retrieve manifest at $commitHash from git"
        return $false
    }
    try {
        $expected = ($historical -join [Environment]::NewLine | ConvertFrom-Json).version
        Write-ChillUtf8 ($historical -join [Environment]::NewLine) $file.ManifestPath
        Invoke-ChillScoopUpdate $name $options
        # Scoop can return without updating (e.g. when the app is running).
        if ((Select-CurrentVersion -AppName $name) -ne $expected) {
            Write-Warning "$($name): requested $expected was not installed"
            return $false
        }
        return $true
    } finally {
        git -C $file.BucketRoot checkout HEAD -- $file.RelPath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "${name}: could not restore bucket manifest $($file.ManifestPath)" }
        # The restored manifest is a different blob on disk; drop the memoized log.
        Reset-ChillCache
    }
}

# scoop's update, in this process. $options carries the flags scoop's own
# 'update' takes, so a caller can pass them through without a subprocess.
# By name: scoop #6730 put $force third, and positional arguments then landed
# one parameter late, -q forcing a reinstall and -k and -s going unread.
function Invoke-ChillScoopUpdate([string]$name, [hashtable]$options) {
    update -app $name -global $false -quiet $options.Quiet -independent $options.Independent -suggested $options.Suggested -use_cache $options.UseCache -check_hash $options.CheckHash
}

# A forced app still needs unholding here; ready apps were unheld in the
# decision pass.
function Invoke-ChillAppUpdate([object]$result, [hashtable]$options) {
    if ($result.Action -eq 'Forced') { Set-ChillHold $result.Name $false | Out-Null }
    if ($result.TargetHash) {
        Invoke-ChillHistoricalUpdate $result.Name $result.TargetHash $result.TargetFile $options | Out-Null
        return
    }
    Invoke-ChillScoopUpdate $result.Name $options
}

#endregion
