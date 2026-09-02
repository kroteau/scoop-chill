#requires -Version 5.1
# Usage: scoop chill [<subcommand>] [<apps>] [options]
# Summary: Update apps only once their manifest has aged
# Help: 'scoop chill' updates apps like 'scoop update', except an app is held
# back until its manifest has sat in the bucket for a while, so you are not the
# one who finds out a release is broken. Held apps are held with scoop's own
# hold, and released automatically once they age past the gate.
#
#     scoop chill                      update everything past the age gate
#     scoop chill firefox -f           ignore the gate for one app
#     scoop chill status               show the table, change nothing
#     scoop chill pin firefox 141.0    install that version when it has aged
#     scoop chill pin firefox          pin the next version after the installed one
#     scoop chill unpin firefox
#     scoop chill versions firefox     versions known to bucket history
#     scoop chill proxy                show proxy settings
#     scoop chill proxy set <host:port>  store the proxy ('none' clears it)
#     scoop chill proxy add firefox    route this app's downloads through it
#     scoop chill proxy rm firefox
#     scoop chill reset                discard local changes in every bucket
#     scoop chill reset extras         and in just one
#
# Options:
#   -f, --force            Update named apps regardless of age or hold
#   -d, --dry-run          Report every write this would make, make none of them
#   -n, --no-refresh       Skip the bucket refresh regardless of its age
#   -a, --min-age <days>   Days a version must be available before installing
#   -c, --count <n>        Versions to list ('versions' only, default 5)
#   -k, --no-cache         Don't use the download cache
#   -s, --skip-hash-check  Skip hash validation (use with caution!)
#   -q, --quiet            Hide extraneous messages
#
# Settings:
#   chill_min_age_days            Default age gate in days (default 7)
#   chill_refresh_max_age_hours   Hours before a bucket refresh is stale (default 1)
# Persistent settings in persist\scoop-chill\_scoop_chill.json:
#   Proxy                         [user:pass@]host:port, scoop's own proxy format,
#                                 used by apps marked with 'chill proxy add'

# $coreRoot is scoop's own install root, set by the core.ps1 that scoop.ps1 has
# already loaded. A command living in 'shims' rather than 'libexec' cannot reach
# the libs the way the built-in commands do, with '$PSScriptRoot\..\lib'.
. "$coreRoot\lib\getopt.ps1"
. "$coreRoot\lib\json.ps1"
. "$coreRoot\lib\system.ps1"
. "$coreRoot\lib\shortcuts.ps1"
. "$coreRoot\lib\psmodules.ps1"
. "$coreRoot\lib\decompress.ps1"
. "$coreRoot\lib\manifest.ps1"
. "$coreRoot\lib\versions.ps1"
. "$coreRoot\lib\depends.ps1"
. "$coreRoot\lib\install.ps1"
. "$coreRoot\lib\download.ps1"
if (get_config USE_SQLITE_CACHE) {
    . "$coreRoot\lib\database.ps1"
}
. "$PSScriptRoot\chill-lib.ps1"

# Borrow scoop's own 'update' rather than shelling out once per app: a child
# process would not inherit the proxy this one sets. scoop-update.ps1 cannot be
# dot-sourced, since its top-level code parses $args and runs an update, so take
# just that one function definition.
#
# Only 'update'. Its neighbours Sync-Scoop and Sync-Bucket resolve scoop's libs
# through $PSScriptRoot, which in a re-created function is this script's
# directory, not scoop's libexec; their parallel jobs then dot-source a path that
# does not exist and lose every scoop function. $PSScriptRoot cannot be
# reassigned to paper over it - the automatic value wins inside the function.
$updateScript = "$coreRoot\libexec\scoop-update.ps1"
$updateAst = [System.Management.Automation.Language.Parser]::ParseFile($updateScript, [ref]$null, [ref]$null)
$updateAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object Name -EQ 'update' |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$subCommands = @('status', 'pin', 'unpin', 'versions', 'proxy', 'reset')
$subCommand = if ($args.Count -gt 0 -and $args[0] -in $subCommands) { $args[0] } else { $null }
$rest = if ($subCommand) { @($args | Select-Object -Skip 1) } else { @($args) }

$opt, $apps, $err = getopt $rest 'fdna:c:ksq' 'force', 'dry-run', 'no-refresh', 'min-age=', 'count=', 'no-cache', 'skip-hash-check', 'quiet'
if ($err) { "scoop chill: $err"; exit 1 }
$force     = $opt.f -or $opt.force
$dryRun    = $opt.d -or $opt.'dry-run'
$noRefresh = $opt.n -or $opt.'no-refresh'
$quiet     = $opt.q -or $opt.quiet
$minAge    = if ($opt.a) { $opt.a } elseif ($opt.'min-age') { $opt.'min-age' } else { get_config CHILL_MIN_AGE_DAYS 7 }
$count     = if ($opt.c) { $opt.c } elseif ($opt.count) { $opt.count } else { 5 }
$apps      = @($apps)

if (!(Test-GitAvailable)) {
    error 'git is required to read bucket history. Run: scoop install git'
    exit 1
}

$stateDir = Get-ChillStateDir
$now      = Get-Date

# Options scoop's own 'update' takes, passed through untouched.
$updateOptions = @{
    Quiet       = $quiet
    Independent = $false
    Suggested   = @{}
    UseCache    = !($opt.k -or $opt.'no-cache')
    CheckHash   = !($opt.s -or $opt.'skip-hash-check')
}

# State is one file per app name, so a name that is not an installed app is a
# typo or an argument in the wrong position, and must not reach the filesystem:
# 'proxy add 127.0.0.1:10809' wrote to an NTFS alternate data stream, since the
# colon turned the state path into one, and only the rename failed.
function Test-ChillApp([string]$name) {
    if (installed $name $false) { return $true }
    error "'$name' isn't an installed app."
    return $false
}

# Gate every write: announce it under --dry-run and report whether to go ahead.
# Stands in for SupportsShouldProcess, which a scoop command cannot use, since it
# takes a getopt string rather than cmdlet parameters.
function Confirm-ChillWrite([string]$intent) {
    if ($dryRun) { Write-Host "  would $intent" -ForegroundColor DarkGray }
    return !$dryRun
}

# One row per app worth deciding about: outdated, or pinned and therefore due to
# move even when scoop considers it current. Pure: it reads state, never writes.
function Get-ChillReport([string[]]$named, [int]$minAgeDays, [string[]]$forced) {
    $cutoff = $now.AddDays(-$minAgeDays)
    $names  = if ($named) { $named } else { @(installed_apps $false) }
    $rows   = [System.Collections.Generic.List[object]]::new()
    $index  = 0

    foreach ($name in $names) {
        $index++
        Write-Progress -Activity 'Checking apps' -Status $name -PercentComplete ($index / [Math]::Max($names.Count, 1) * 100)

        $status = app_status $name $false
        # An install that stopped partway leaves the app directory without a
        # working 'current', which reads as not installed. Report it instead of
        # warning that an app the user can see in 'scoop list' is missing, and
        # never update it: it needs 'scoop install', not another update pass.
        if ($status.failed) {
            $rows.Add([pscustomobject]@{
                Name         = $name
                Installed    = ''
                Latest       = ''
                'First Seen' = ''
                Age          = 0
                Proxy        = ''
                Pin          = ''
                Action       = 'Failed'
                Entry        = $null
                Decision     = $null
            })
            continue
        }
        if (!$status.installed) { warn "'$name' isn't installed."; continue }
        $stored = Get-ChillState $name $stateDir
        $isPinned = $stored -and $stored['PinnedVersion']
        if (!$status.outdated -and !$isPinned -and $name -notin $forced) { continue }

        $file     = Find-ChillManifest $name
        $latest   = if ($status.latest_version) { $status.latest_version } else { $status.version }
        $entry    = Resolve-ChillEntry $name $latest (Get-ChillManifestDate $file) $file $stored $now
        $decision = Get-ChillDecision $entry (@{ name = $name } + $status) $cutoff ([bool]($name -in $forced))

        $age = if ($decision.Gate) { [int][math]::Floor(($now - $decision.Gate).TotalDays) } else { 0 }
        $rows.Add([pscustomobject]@{
            Name         = $name
            Installed    = $status.version
            Latest       = $latest
            'First Seen' = $entry.FirstSeen.ToString('yyyy-MM-dd')
            Age          = $age
            Proxy        = if ($entry['Proxy']) { '*' } else { '' }
            Pin          = if ($entry['PinnedVersion']) { $entry['PinnedVersion'] } else { '' }
            Action       = $decision.Action
            Entry        = $entry
            Decision     = $decision
        })
    }

    Write-Progress -Activity 'Checking apps' -Completed
    # Actionable rows last, next to the summary line under the table.
    return @($rows | Sort-Object { @('Failed', 'Held', 'ManualHold', 'Ready', 'Forced').IndexOf($_.Action) }, Age)
}

function Show-ChillReport([object[]]$rows) {
    $rows | Format-Table -AutoSize -Property Name, Installed, Latest, 'First Seen', Age, Proxy, Pin, Action
    $ready  = @($rows | Where-Object { $_.Action -in 'Ready', 'Forced' })
    $proxied = @($ready | Where-Object Proxy -EQ '*').Count
    $pinned  = @($ready | Where-Object Pin -NE '').Count
    $held    = @($rows | Where-Object Action -EQ 'Held').Count
    $manual  = @($rows | Where-Object Action -EQ 'ManualHold').Count
    $failed  = @($rows | Where-Object Action -EQ 'Failed')
    Write-Host "$($ready.Count) ready ($proxied proxy), $held held, $manual manual, $pinned pinned." -ForegroundColor Cyan
    if ($failed) {
        error "Install left unfinished: $($failed.Name -join ', '). Repair with: scoop install $($failed.Name -join ' ')"
    }
}

function Invoke-ChillRun([object[]]$rows) {
    foreach ($row in $rows) {
        if ($row.Action -eq 'Failed') { continue }
        $entry = $row.Entry
        if ($row.Decision.Ready -and $entry.ScriptHeld) {
            if ((Confirm-ChillWrite "unhold $($row.Name)") -and (Set-ChillHold $row.Name $false)) { $entry.ScriptHeld = $false }
        } elseif (!$row.Decision.Ready -and !$row.Decision.ManualHold -and !$entry.ScriptHeld) {
            if ((Confirm-ChillWrite "hold $($row.Name)") -and (Set-ChillHold $row.Name $true)) { $entry.ScriptHeld = $true }
        }
        if (Confirm-ChillWrite "record state for $($row.Name)") { Set-ChillState $row.Name $entry $stateDir }
    }

    # Update Chill itself last because Scoop may abort this script on failure.
    # Preserve report order for every other app; the original index makes that
    # ordering stable on every supported runtime.
    $sortIndex = 0
    $toUpdate = @($rows | Where-Object { $_.Action -in 'Ready', 'Forced' } |
        ForEach-Object {
            [pscustomobject]@{ Row = $_; ChillLast = ($_.Name -eq 'scoop-chill'); Index = $sortIndex }
            $sortIndex++
        } |
        Sort-Object ChillLast, Index |
        ForEach-Object { $_.Row })
    if ($toUpdate.Count -eq 0) {
        Write-Host 'Nothing to update.' -ForegroundColor Green
        return
    }

    $proxyUrl = (Get-ChillSettings $stateDir)['Proxy']
    if (!$proxyUrl -and @($toUpdate | Where-Object Proxy -EQ '*')) {
        warn "Proxy apps are ready but no url is stored. Run: scoop chill proxy set <url>"
        return
    }

    foreach ($row in $toUpdate) {
        $verb  = if ($row.Action -eq 'Forced') { 'force-update' } else { 'update' }
        $label = if ($row.Action -eq 'Forced') { 'Force-updating' } else { 'Updating' }
        $notes = @()
        if ($row.Pin -ne '') { $notes += "pinned $($row.Pin)" }
        if ($row.Proxy -eq '*') { $notes += 'proxy' }
        $tag = if ($notes) { " ($($notes -join ', '))" } else { '' }
        if (!(Confirm-ChillWrite "$verb $($row.Name)$tag")) { continue }
        Write-Host "  $label$($tag): $($row.Name)" -ForegroundColor Yellow

        # Proxy is now just an attribute of the app, applied around its own
        # update, so proxied apps no longer need a pass of their own.
        # Not .GetNewClosure(): that binds the scriptblock to a dynamic module,
        # whose function lookup skips this script's scope, so every name defined
        # in chill-lib.ps1 goes missing. A plain scriptblock resolves both the
        # functions and $row up the call stack.
        $url = if ($row.Proxy -eq '*') { $proxyUrl } else { $null }
        $finished = $false
        try {
            Invoke-ChillProxied $url { Invoke-ChillAppUpdate $row $stateDir $updateOptions }
            $finished = $true
        } finally {
            # scoop reports a failed download or hash with abort, which is
            # 'exit 1': not catchable, and it ends this script, so every app left
            # in the pass is skipped without explanation. A finally still runs,
            # so this is the only chance to name the app that stopped the run.
            if (!$finished) {
                error "'$($row.Name)' did not finish updating; the rest of this run was skipped."
            }
        }
    }
}

function Show-ChillVersions([string]$name, [int]$wanted) {
    $file = Find-ChillManifest $name
    if (!$file) { error "No bucket manifest found for '$name'."; return }
    $log = Get-ChillLog $file
    if (!$log -or $log.Hashes.Count -eq 0) { error "No git history found for '$name'."; return }

    $state     = Get-ChillState $name $stateDir
    $pinned    = if ($state) { $state['PinnedVersion'] } else { $null }
    $installed = Select-CurrentVersion -AppName $name
    $seen      = [System.Collections.Generic.HashSet[string]]::new()
    $rows      = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; ; $i++) {
        Expand-ChillLog $log ($i + 1)
        if ($i -ge $log.Hashes.Count) { break }
        $hash = $log.Hashes[$i]
        $ver  = Get-ChillVersionAt $file $log $i
        if ($ver -and $seen.Add($ver)) {
            $date = ConvertTo-ChillDate $log.Dates[$hash]
            $rows.Add([pscustomobject]@{
                Version   = $ver
                Date      = if ($date) { $date.ToString('yyyy-MM-dd') } else { '' }
                Hash      = $hash.Substring(0, 7)
                Installed = if ($ver -eq $installed) { '*' } else { '' }
                Pinned    = if ($ver -eq $pinned) { '*' } else { '' }
            })
            if ($rows.Count -ge $wanted) { break }
        }
    }
    $rows | Format-Table -AutoSize
}

function Show-ChillPin([string]$name) {
    $state = Get-ChillState $name $stateDir
    if (!$state -or !$state['PinnedVersion']) { return }
    $date = ConvertTo-ChillDate $state['PinnedDate']
    [pscustomobject]@{
        Name      = $name
        Installed = Select-CurrentVersion -AppName $name
        Pin       = $state['PinnedVersion']
        Pinned    = if ($date) { $date.ToString('yyyy-MM-dd') } else { '' }
        Age       = if ($date) { [int][math]::Floor(($now - $date).TotalDays) } else { $null }
    }
}

function Invoke-ChillProxyCommand([string[]]$arguments) {
    $action = $arguments[0]
    $rest   = @($arguments | Select-Object -Skip 1)
    switch ($action) {
        'set' {
            if (!$rest) { error 'Usage: scoop chill proxy set [<user>:<pass>@]<host>:<port> | none'; exit 1 }
            $address = ConvertTo-ChillProxyAddress $rest[0]
            if (!(Confirm-ChillWrite "set the proxy to $address")) { break }
            $proxyValue = if ($rest[0] -eq 'none') { $null } else { $address }
            $proxyMessage = if ($rest[0] -eq 'none') { 'cleared' } else { "set to $address" }
            Set-ChillSetting 'Proxy' $proxyValue $stateDir
            success "Proxy $proxyMessage."
        }
        { $_ -in 'add', 'rm' } {
            if (!$rest) { error "Usage: scoop chill proxy $action <apps>"; exit 1 }
            foreach ($name in $rest) {
                if (!(Test-ChillApp $name)) { continue }
                if (!(Confirm-ChillWrite "mark $name as $(if ($action -eq 'add') { 'proxied' } else { 'not proxied' })")) { continue }
                Update-ChillState $name $stateDir @{ Proxy = ($action -eq 'add') } | Out-Null
                success "'$name' $(if ($action -eq 'add') { 'routed through the proxy' } else { 'no longer proxied' })."
            }
        }
        default {
            $url = (Get-ChillSettings $stateDir)['Proxy']
            Write-Host "url: $(if ($url) { $url } else { '<not set>' })"
            $proxied = @(Get-ChildItem $stateDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Where-Object { (Read-ChillJson $_.FullName @{})['Proxy'] } | ForEach-Object BaseName)
            Write-Host "apps: $(if ($proxied) { $proxied -join ', ' } else { '<none>' })"
        }
    }
}

switch ($subCommand) {
    'status' {
        Show-ChillReport (Get-ChillReport $apps $minAge @())
    }
    'pin' {
        if (!$apps) { error 'Usage: scoop chill pin <app> [<version>]'; exit 1 }
        $name = $apps[0]
        if (!(Test-ChillApp $name)) { exit 1 }
        # A bare pin steps one release forward from what is installed.
        $version = if ($apps.Count -gt 1) { $apps[1] } else { Resolve-ChillNextPin $name }
        if (!$version) { exit 1 }
        if (Confirm-ChillWrite "pin $name to $version") {
            Set-ChillPin $name $version $stateDir
            # Report from state, not from intent: Set-ChillPin refuses a version
            # it cannot find in history, and reporting the request would lie.
            Show-ChillPin $name | Format-Table -AutoSize
        }
    }
    'unpin' {
        if (!$apps) { error 'Usage: scoop chill unpin <app>'; exit 1 }
        foreach ($name in $apps) {
            if (!(Test-ChillApp $name)) { continue }
            if (Confirm-ChillWrite "unpin $name") { Clear-ChillPin $name $stateDir; success "'$name' unpinned." }
        }
    }
    'versions' {
        if (!$apps) { error 'Usage: scoop chill versions <app>'; exit 1 }
        Show-ChillVersions $apps[0] $count
    }
    'proxy' {
        Invoke-ChillProxyCommand $apps
    }
    'reset' {
        $known = @(Get-LocalBucket)
        foreach ($name in $apps) {
            if ($name -notin $known) { error "'$name' isn't an installed bucket."; exit 1 }
        }
        $dirty = @(Get-ChillDirtyBucket $apps)
        if ($dirty.Count -eq 0) { Write-Host 'Every bucket is clean.' -ForegroundColor Green; break }
        foreach ($bucket in $dirty) {
            Write-Host "$($bucket.Bucket): $($bucket.Changes.Count) changed" -ForegroundColor Yellow
            $bucket.Changes | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
            if (!(Confirm-ChillWrite "discard them in $($bucket.Root)")) { continue }
            if (Reset-GitBucket $bucket.Root) { success "'$($bucket.Bucket)' reset to HEAD." }
            else { error "'$($bucket.Bucket)' could not be reset." }
        }
        # Manifests may have moved back; drop the index built from the old tree.
        Reset-ChillCache
    }
    default {
        if ($force -and !$apps) { error '--force needs an app name.'; exit 1 }

        $refreshMaxAge = get_config CHILL_REFRESH_MAX_AGE_HOURS 1
        $lastRefresh   = ConvertTo-ChillDate (Get-ChillSettings $stateDir)['LastRefresh']
        $stale = $null -eq $lastRefresh -or ($now - $lastRefresh).TotalHours -gt $refreshMaxAge
        # scoop's own update script, run whole, which is a plain 'scoop update':
        # it syncs scoop and the buckets and updates no apps, since it gets no
        # app arguments. Called rather than borrowed so its $PSScriptRoot, and
        # the parallel bucket fetch that depends on it, still resolve.
        if (!$noRefresh -and $stale -and (Confirm-ChillWrite 'refresh scoop and buckets')) {
            & $updateScript
            Set-ChillSetting 'LastRefresh' ($now.ToString('o')) $stateDir
            # The refresh may have moved manifests; drop the index built before it.
            Reset-ChillCache
        }

        $forcedApps = if ($force) { $apps } else { @() }
        $rows = Get-ChillReport $apps $minAge $forcedApps
        Show-ChillReport $rows
        Invoke-ChillRun $rows
    }
}

exit 0
