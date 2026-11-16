#requires -Version 5.1
# Usage: scoop chill [<subcommand>] [<apps>] [options]
# Summary: Update apps only once their manifest has aged
# Help: 'scoop chill' updates apps like 'scoop update', except an app is held
# back until its manifest has sat in the bucket for a while, so you are not the
# one who finds out a release is broken. An outdated app moves to the newest
# version in bucket history that has aged, which may be short of latest. Held
# apps are held with scoop's own hold, and released once a version ages.
#
#     scoop chill                      show the table, record new versions
#     scoop chill *                    update everything past the age gate
#     scoop chill firefox -f           ignore the gate for one app
#     scoop chill firefox@141.0        update using that version's Git manifest
#     scoop chill status [firefox]     show the table, record new versions
#     scoop chill versions firefox     versions known to bucket history
#     scoop chill proxy                show proxy settings
#     scoop chill proxy set <host:port>  store the proxy ('none' clears it)
#     scoop chill proxy add firefox    route this app's downloads through it
#     scoop chill proxy rm firefox
#     scoop chill reset                discard local changes in every bucket
#     scoop chill reset extras         and in just one
#
# Options:
#   -f, --force, -Force    Update named apps to latest regardless of age or hold
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

$subCommands = @('status', 'versions', 'proxy', 'reset')
$subCommand = if ($args.Count -gt 0 -and $args[0] -in $subCommands) { $args[0] } else { $null }
$rest = if ($subCommand) { @($args | Select-Object -Skip 1) } else { @($args) }
$rest = @($rest | ForEach-Object { if ($_ -ieq '-force') { '--force' } else { $_ } })

$opt, $apps, $err = getopt $rest 'fdna:c:ksq' 'force', 'dry-run', 'no-refresh', 'min-age=', 'count=', 'no-cache', 'skip-hash-check', 'quiet'
if ($err) { "scoop chill: $err"; exit 1 }
$force     = $opt.f -or $opt.force
$dryRun    = $opt.d -or $opt.'dry-run'
$noRefresh = $opt.n -or $opt.'no-refresh'
$quiet     = $opt.q -or $opt.quiet
$minAge    = if ($opt.a) { $opt.a } elseif ($opt.'min-age') { $opt.'min-age' } else { get_config CHILL_MIN_AGE_DAYS 7 }
$count     = if ($opt.c) { $opt.c } elseif ($opt.count) { $opt.count } else { 5 }
$apps      = @($apps)
$isEveryApp = $apps.Count -eq 1 -and $apps[0] -eq '*'
if ($isEveryApp) { $apps = @(installed_apps $false) }

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

# One row per app worth deciding about: outdated, forced, or given a version.
# Pure: it reads state, never writes.
# An outdated app steps to the newest version in bucket history past the age
# gate, never straight to latest. Every version installs from its newest
# manifest.
function Get-ChillReport([string[]]$named, [int]$minAgeDays, [string[]]$forced) {
    $cutoff = $now.AddDays(-$minAgeDays)
    $names  = if ($named) { $named } else { @(installed_apps $false) }
    $rows   = [System.Collections.Generic.List[object]]::new()
    $index  = 0

    foreach ($target in @(ConvertTo-ChillTargets $names)) {
        $name     = $target.Name
        $isForced = $name -in $forced -or $target.Argument -in $forced
        $index++
        Write-Progress -Activity 'Checking apps' -Status $name -PercentComplete ($index / [Math]::Max($names.Count, 1) * 100)

        $status = app_status $name $false
        # An install that stopped partway leaves the app directory without a
        # working 'current', which reads as not installed. Report it instead of
        # warning that an app the user can see in 'scoop list' is missing, and
        # never update it: it needs 'scoop install', not another update pass.
        if ($status.failed) {
            $rows.Add([pscustomobject]@{
                Name          = $name
                Installed     = ''
                Latest        = ''
                Published     = ''
                TargetVersion = $null
                TargetSource  = $null
                Behind        = $null
                Indexed       = ''
                Age           = $null
                Proxy         = ''
                IsHeld        = $false
                Action        = 'Failed'
                Entry         = $null
                Decision      = $null
            })
            continue
        }
        if (!$status.installed) { warn "'$name' isn't installed."; continue }
        if (!$status.outdated -and !$isForced -and !$target.Version) { continue }
        $entry = ConvertTo-ChillEntry (Get-ChillState $name $stateDir)

        $file     = Find-ChillManifest $name
        $latest    = if ($status.latest_version) { $status.latest_version } else { $status.version }
        $requested = $null
        if ($target.Version) {
            if ((install_info $name $status.version $false).url) {
                Write-Warning "${name}: version targets require a bucket-installed app; skipping URL install"
                continue
            }
            $requested = Find-ChillVersionRun $target.Version $file
            if (!$requested.Newest.Hash -or !$requested.Original.Date) {
                Write-Warning "${name}: version $($target.Version) not found with a date in bucket history; skipping"
                continue
            }
        }
        $latestRun = Find-ChillVersionRun $latest $file
        # Each version this row might install ages from when chill first saw
        # it. A version seen for the first time counts as seen now; the run
        # records it.
        $versions  = @(Get-ChillNewerVersions $file $status.version)
        $firstSeen = Get-ChillFirstSeen $entry.Seen (@($versions | ForEach-Object { $_.Version }) + $requested.Version + $latestRun.Version) $now
        foreach ($run in @($versions) + $requested + $latestRun) {
            if ($run) { $run.Seen = $firstSeen.Dates[$run.Version] }
        }
        # Forcing goes straight to latest, so it needs no step. A version whose
        # install fields changed after its release is never a step, and is
        # warned about until a newer version passes the gate.
        $step = $null
        if (!$target.Version -and !$isForced) {
            foreach ($run in $versions) { $run.Rewrite = Find-ChillInstallRewrite $file $run }
            $step = Select-ChillUpdateTarget @($versions | Where-Object { !$_.Rewrite }) $cutoff
            $isStepAged = $step -and $step.Seen -lt $cutoff
            # Newest first: rewrites above an aged step are skipped ones, and
            # anything below it is already passed.
            foreach ($run in $versions) {
                if ($run.Rewrite) {
                    Write-Warning ("${name}: $($run.Version)'s {2} changed on {0:yyyy-MM-dd}, after its release on {1:yyyy-MM-dd}. Skipped until a newer version passes the age gate; to take it, run: scoop chill $name@$($run.Version)" -f $run.Rewrite.Date, $run.Original.Date, ($run.Rewrite.Fields -join ', '))
                }
                if ($isStepAged -and $run.Version -eq $step.Version) { break }
            }
        }
        $chosen = if ($requested) { $requested } elseif ($isForced) { $latestRun } else { $step }
        if ($chosen -and !$step) { $chosen.Rewrite = Find-ChillInstallRewrite $file $chosen }

        $decisionEntry = $entry.Clone()
        if ($requested) {
            $decisionEntry.TargetDate = $requested.Seen
        } elseif ($step) {
            $decisionEntry.TargetDate = $step.Seen
        }
        $decision = Get-ChillDecision $decisionEntry (@{ name = $name } + $status) $cutoff $isForced
        if ($target.Version -and $status.version -eq $target.Version) {
            $decision.Action = 'Current'
            $decision.Ready = $false
        }

        # Say which manifest this run takes, and why, when that is not simply
        # the aged release: what -f bypasses, and what changed since release.
        if ($chosen -and $decision.Action -ne 'Current') {
            if ($isForced) { Write-Warning "${name}: -f installs $($chosen.Version), ignoring the age gate and holds." }
            if ($chosen.Rewrite) {
                Write-Warning ("${name}: $($chosen.Version)'s {2} changed on {0:yyyy-MM-dd}, after its release on {1:yyyy-MM-dd}; installing the changed manifest." -f $chosen.Rewrite.Date, $chosen.Original.Date, ($chosen.Rewrite.Fields -join ', '))
            } elseif ($chosen.Commits.Count -gt 1) {
                # Not skipped, since what is installed is the same, but any
                # edit after a release is worth a look before it lands.
                Write-Warning ("${name}: $($chosen.Version)'s manifest was edited on {0:yyyy-MM-dd}, after its release on {1:yyyy-MM-dd}; nothing it installs or runs changed." -f $chosen.Newest.Date, $chosen.Original.Date)
            }
        }

        # Every version installs from its newest manifest: a later commit that
        # kept the install fields only fixes it, and one that changed them is
        # taken only when asked for.
        $commit = if ($requested) { $requested.Newest } elseif ($step) { $step.Newest } else { $null }
        # A step that is the bucket's HEAD needs no historical manifest.
        $isHead = $commit -and !$requested -and $commit.Hash -eq (Get-ChillLog $file).Hashes[0]
        $targetHash = if ($commit -and !$isHead) { $commit.Hash } else { $null }

        # The version this row would install, which Indexed and Age describe.
        $latestDate = $latestRun.Original.Date
        $targetSource, $targetVersion, $indexedDate =
            if ($requested)    { 'Requested', $target.Version, $decision.Gate }
            elseif ($isForced) { 'Latest', $latest, $latestRun.Seen }
            elseif ($step)     { 'Step', $step.Version, $decision.Gate }
            else               { $null, $null, $null }
        $behind = if ($targetVersion) { Measure-ChillVersionsBehind $file $targetVersion } else { $null }

        $rows.Add([pscustomobject]@{
            Name          = $name
            Installed     = $status.version
            Latest        = $latest
            Published     = if ($latestDate) { $latestDate.ToString('yyyy-MM-dd') } else { '' }
            TargetVersion = $targetVersion
            TargetSource  = $targetSource
            Behind        = $behind
            TargetHash    = $targetHash
            TargetFile    = if ($targetHash) { $file } else { $null }
            Indexed       = if ($indexedDate) { $indexedDate.ToString('yyyy-MM-dd') } else { '' }
            Age           = if ($indexedDate) { [int][math]::Floor(($now - $indexedDate).TotalDays) } else { $null }
            Proxy         = if ($entry['Proxy']) { '*' } else { '' }
            IsHeld        = [bool]$status.hold
            Action        = $decision.Action
            Entry         = $entry
            Decision      = $decision
            Seen          = $firstSeen.Dates
            NewlySeen     = $firstSeen.Unrecorded
        })
    }

    Write-Progress -Activity 'Checking apps' -Completed
    # Actionable rows last, next to the summary line under the table.
    return @($rows | Sort-Object { @('Failed', 'Current', 'Held', 'ManualHold', 'Ready', 'Forced').IndexOf($_.Action) }, Age)
}

# Target carries '(-N)' for the versions still newer than it, '(?)' when history
# does not know it. Action carries '^' for an app routed through the proxy.
function Show-ChillReport([object[]]$rows) {
    $targetCell = {
        if (!$_.TargetVersion) { return '' }
        $distance = if ($null -eq $_.Behind) { ' (?)' } elseif ($_.Behind -gt 0) { " (-$($_.Behind))" } else { '' }
        "$($_.TargetVersion)$distance"
    }
    $actionCell = { if ($_.Proxy -eq '*') { "$($_.Action)^" } else { $_.Action } }
    $rows | Format-Table -AutoSize -Property Name, Installed, Latest, Published, @{ Label = 'Target'; Expression = $targetCell }, Indexed, Age, @{ Label = 'Action'; Expression = $actionCell }
    $ready  = @($rows | Where-Object { $_.Action -in 'Ready', 'Forced' })
    $proxied = @($ready | Where-Object Proxy -EQ '*').Count
    $held    = @($rows | Where-Object Action -EQ 'Held').Count
    $manual  = @($rows | Where-Object Action -EQ 'ManualHold').Count
    $failed  = @($rows | Where-Object Action -EQ 'Failed')
    Write-Host "$($ready.Count) ready ($proxied proxy), $held held, $manual manual." -ForegroundColor Cyan
    if ($failed) {
        error "Install left unfinished: $($failed.Name -join ', '). Repair with: scoop install $($failed.Name -join ' ')"
    }
}

# Record the versions the report saw for the first time: they age from now.
# A report records them too, or a version only ever looked at would show age 0
# every day and never pass the gate.
function Save-ChillFirstSeen([object[]]$rows) {
    foreach ($row in $rows) {
        if ($row.Action -in 'Failed', 'Current' -or !$row.NewlySeen) { continue }
        if (Confirm-ChillWrite "record $($row.Name) $($row.NewlySeen -join ', ') as first seen now") {
            Update-ChillState $row.Name $stateDir @{ Seen = $row.Seen } | Out-Null
        }
    }
}

function Invoke-ChillRun([object[]]$rows) {
    # Before an update can end the run, whatever else happens to the app.
    Save-ChillFirstSeen $rows

    # Hold what is not ready. A ready app keeps its hold until its own update
    # starts, so one this run never reaches is still held afterwards. The state
    # alone is not trusted: a hold recorded as chill's but lost to 'scoop
    # unhold' or a reinstall is placed again.
    foreach ($row in $rows) {
        if ($row.Action -in 'Failed', 'Current') { continue }
        if ($row.Decision.Ready -or $row.Decision.ManualHold -or $row.IsHeld) { continue }
        if (Confirm-ChillWrite "hold $($row.Name)") { Set-ChillOwnedHold $row.Name $true $stateDir }
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
        warn "Proxy apps are ready but no url is stored; skipping them. Run: scoop chill proxy set <url>"
        $toUpdate = @($toUpdate | Where-Object Proxy -NE '*')
    }

    foreach ($row in $toUpdate) {
        $verb  = if ($row.Action -eq 'Forced') { 'force-update' } else { 'update' }
        $label = if ($row.Action -eq 'Forced') { 'Force-updating' } else { 'Updating' }
        $notes = @()
        if ($row.TargetSource -in 'Requested', 'Step') { $notes += "version $($row.TargetVersion)" }
        if ($row.Proxy -eq '*') { $notes += 'proxy' }
        $tag = if ($notes) { " ($($notes -join ', '))" } else { '' }
        if (!(Confirm-ChillWrite "$verb $($row.Name)$tag")) { continue }
        Write-Host "  $label$($tag): $($row.Name)" -ForegroundColor Yellow
        if ($row.Entry.ScriptHeld) { Set-ChillOwnedHold $row.Name $false $stateDir }

        # Proxy is now just an attribute of the app, applied around its own
        # update, so proxied apps no longer need a pass of their own.
        # Not .GetNewClosure(): that binds the scriptblock to a dynamic module,
        # whose function lookup skips this script's scope, so every name defined
        # in chill-lib.ps1 goes missing. A plain scriptblock resolves both the
        # functions and $row up the call stack.
        $url = if ($row.Proxy -eq '*') { $proxyUrl } else { $null }
        $finished = $false
        try {
            Invoke-ChillProxied $url { Invoke-ChillAppUpdate $row $updateOptions }
            $finished = $true
        } finally {
            # Hold again whatever is still short of latest: a step on the way
            # there, or an update that did not land. A fresh install.json
            # carries no hold, so a step would otherwise be left open to a
            # plain 'scoop update'. A manual hold that -f overrode is put back
            # whatever happened, and stays the user's: -f was for this run only.
            if ($row.Decision.ManualHold) {
                Set-ChillHold $row.Name $true | Out-Null
            } elseif ((Select-CurrentVersion -AppName $row.Name) -ne $row.Latest) {
                Set-ChillOwnedHold $row.Name $true $stateDir
            }
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
            })
            if ($rows.Count -ge $wanted) { break }
        }
    }
    $rows | Format-Table -AutoSize
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
        $rows = Get-ChillReport $apps $minAge @()
        Show-ChillReport $rows
        Save-ChillFirstSeen $rows
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
        if (!$apps) {
            $rows = Get-ChillReport @() $minAge @()
            Show-ChillReport $rows
            Save-ChillFirstSeen $rows
            break
        }

        ConvertTo-ChillTargets $apps | Out-Null
        $refreshMaxAge = get_config CHILL_REFRESH_MAX_AGE_HOURS 1
        $lastRefresh   = ConvertTo-ChillDate (Get-ChillSettings $stateDir)['LastRefresh']
        $stale = $null -eq $lastRefresh -or ($now - $lastRefresh).TotalHours -gt $refreshMaxAge
        # scoop's own update script, run whole, which is a plain 'scoop update':
        # it syncs scoop and the buckets and updates no apps, since it gets no
        # app arguments. Called rather than borrowed so its $PSScriptRoot, and
        # the parallel bucket fetch that depends on it, still resolve.
        if (!$noRefresh -and $stale -and (Confirm-ChillWrite 'refresh scoop and buckets')) {
            $refreshStart = Get-Date
            & $updateScript
            # The refresh may have moved manifests; drop the index built before it.
            Reset-ChillCache
            # Record the refresh only if every bucket took it, so a failed one is
            # retried next run rather than trusted as fresh for the next hour.
            $unsynced = @(Get-ChillUnsyncedBucket $refreshStart)
            foreach ($bucket in $unsynced) {
                $hint = if ($bucket.IsDirty) { "; it has local changes, discard them with: scoop chill reset $($bucket.Bucket)" } else { '' }
                warn "'$($bucket.Bucket)' did not refresh ($($bucket.Reason)), so its manifests may be out of date$hint"
            }
            if (!$unsynced) { Set-ChillSetting 'LastRefresh' ($now.ToString('o')) $stateDir }
        }

        $forcedApps = if ($force) { $apps } else { @() }
        $rows = Get-ChillReport $apps $minAge $forcedApps
        Show-ChillReport $rows
        Invoke-ChillRun $rows
    }
}

exit 0
