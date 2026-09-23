#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version
)

# Release settings; paths are relative to this script unless noted otherwise.
$app                 = 'scoop-chill'
$remoteName          = 'origin'
$tagPrefix           = 'v'
$bucketDirectory     = 'bucket'
$testPattern         = 'chill*.tests.ps1'
$hashAlgorithm       = 'SHA256'
$checkverRelativePath = 'bin\checkver.ps1' # Relative to the Scoop installation.
$archiveUrlTemplate  = '{0}/archive/refs/tags/{1}.zip'
$extractDirTemplate  = "$app-{0}"
$commitMessageTemplate = 'update bucket manifest to {0}'

$manifestRelativePath = "$bucketDirectory/$app.json"
$scriptName           = Split-Path -Leaf $PSCommandPath
$resumeEditableFiles  = @('README.md', $manifestRelativePath, $scriptName)
$resumeUntrackedFiles = @($scriptName)

$ErrorActionPreference = 'Stop'
$tag          = "$tagPrefix$Version"
$manifestPath = Join-Path $PSScriptRoot $manifestRelativePath
$bucketPath   = Join-Path $PSScriptRoot $bucketDirectory
$shell        = (Get-Process -Id $PID).Path
$tests        = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter $testPattern -File | Sort-Object Name)
if (!$tests.Count) { throw "No $testPattern files found; release stopped." }

function Invoke-ReleaseGit([string[]]$arguments) {
    $output = & git -C $PSScriptRoot @arguments
    if ($LASTEXITCODE -ne 0) { throw "git $($arguments -join ' ') failed" }
    return $output
}

function Read-ReleaseManifest {
    Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function ConvertTo-ReleaseRepositoryUrl([string]$remoteUrl) {
    if ($remoteUrl -notmatch '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)(?<owner>[\w.-]+)/(?<repo>[\w.-]+?)(?:\.git)?/?$') {
        throw "Remote '$remoteName' must use a GitHub HTTPS or SSH repository URL."
    }
    return "https://github.com/$($Matches.owner)/$($Matches.repo)"
}

$repositoryUrl = ConvertTo-ReleaseRepositoryUrl (Invoke-ReleaseGit @('remote', 'get-url', $remoteName))
$branch = Invoke-ReleaseGit @('branch', '--show-current')
if (!$branch) { throw 'Check out a branch before releasing; detached HEAD cannot publish the manifest.' }

$manifest = Read-ReleaseManifest
if ([version]$manifest.version -gt [version]$Version) {
    throw "Manifest is already newer than $Version; refusing to downgrade it."
}
$remote = @(Invoke-ReleaseGit @('ls-remote', '--tags', $remoteName, "refs/tags/$tag", "refs/tags/$tag^{}"))
$local  = @(Invoke-ReleaseGit @('tag', '--list', $tag))
if (!$local -and $remote.Count -and !$WhatIfPreference) {
    if (!$PSCmdlet.ShouldProcess($tag, "Fetch published tag from $remoteName")) { return }
    Invoke-ReleaseGit @('fetch', $remoteName, "refs/tags/${tag}:refs/tags/$tag")
    $local = @($tag)
}
if ($local) {
    $commit = Invoke-ReleaseGit @('rev-parse', "$tag^{commit}")
    if ($remote.Count) {
        $remoteCommit = ($remote[-1] -split '\s+')[0]
        if ($remoteCommit -ne $commit) { throw "Local and remote $tag differ; refusing to move either tag." }
    }
    # Resume with release metadata edits, but test exactly the tagged application code.
    $exclusions = @($resumeEditableFiles | ForEach-Object { ":(exclude,literal)$_" })
    $changes    = @(Invoke-ReleaseGit (@('diff', '--name-only', $tag, '--', '.') + $exclusions))
    $untracked  = @(Invoke-ReleaseGit @('ls-files', '--others', '--exclude-standard')) |
                  Where-Object { $_ -notin $resumeUntrackedFiles }
    if ($changes.Count -or $untracked) { throw "Working tree differs from $tag outside release metadata. Commit or set aside those changes first." }
    Write-Host "Resuming $tag ($commit)."
} elseif (!$remote.Count) {
    if (@(Invoke-ReleaseGit @('status', '--porcelain')).Count) {
        throw 'A new release requires a clean working tree. Commit the tested changes first.'
    }
    $commit = Invoke-ReleaseGit @('rev-parse', 'HEAD')
}

if ($WhatIfPreference) {
    if (!$local -and $remote.Count) {
        $PSCmdlet.ShouldProcess($tag, "Fetch published tag from $remoteName") | Out-Null
        Write-Host 'Working tree comparison with the published tag is deferred until it is fetched.'
    }
    foreach ($test in $tests) {
        $PSCmdlet.ShouldProcess($test.Name, 'Run test suite') | Out-Null
    }
    if (!$local -and !$remote.Count) {
        $PSCmdlet.ShouldProcess($tag, "Create tag at $commit") | Out-Null
    }
    if (!$remote.Count) {
        $PSCmdlet.ShouldProcess($tag, "Push tag to $remoteName") | Out-Null
    } else {
        Write-Host "$tag is already published."
    }
    $PSCmdlet.ShouldProcess($tag, "Download published archive and calculate $hashAlgorithm") | Out-Null
    $PSCmdlet.ShouldProcess($manifestPath, "Update to $Version only if version, URL, extraction directory, or checksum differs") | Out-Null
    $PSCmdlet.ShouldProcess($manifestRelativePath, 'Commit only this manifest if it has pending changes') | Out-Null
    $PSCmdlet.ShouldProcess("$remoteName/$branch", 'Push current branch, including any pending release commit') | Out-Null
    Write-Host 'Preview complete; tests and archive verification were not run.'
    return
}

if (!$PSCmdlet.ShouldProcess($tag, 'Run tests, publish any missing tag, and verify, commit, and push the manifest')) { return }

foreach ($test in $tests) {
    & $shell -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "$($test.Name) failed; release stopped." }
}

if (!$local) { Invoke-ReleaseGit @('tag', $tag, $commit) }
if (!$remote.Count) {
    Invoke-ReleaseGit @('push', $remoteName, "refs/tags/$tag")
} else {
    Write-Host "$tag is already published."
}

$url        = $archiveUrlTemplate -f $repositoryUrl, $tag
$extractDir = $extractDirTemplate -f $Version
$archive    = [System.IO.Path]::GetTempFileName()
try {
    Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm $hashAlgorithm).Hash.ToLowerInvariant()
} finally {
    Remove-Item -LiteralPath $archive -Force
}

if ($manifest.version -ne $Version -or $manifest.url -ne $url -or
    $manifest.extract_dir -ne $extractDir -or $manifest.hash -ne $hash) {
    $scoopRoot = & scoop prefix scoop
    if ($LASTEXITCODE -ne 0 -or !$scoopRoot) { throw 'Could not locate Scoop.' }
    $checkver = Join-Path "$scoopRoot" $checkverRelativePath
    & $shell -NoProfile -File $checkver $app $bucketPath -Update -ForceUpdate -Version $Version -ThrowError
    if ($LASTEXITCODE -ne 0) { throw 'Manifest update failed. Rerun this script to resume.' }
    $manifest = Read-ReleaseManifest
    if ($manifest.version -ne $Version -or $manifest.url -ne $url -or
        $manifest.extract_dir -ne $extractDir -or $manifest.hash -ne $hash) {
        throw 'Manifest does not match the published archive. Rerun this script to retry.'
    }
} else {
    Write-Host 'Manifest already matches the published archive.'
}

Invoke-ReleaseGit @('diff', '--check', 'HEAD', '--', $manifestRelativePath)
$pending = @(Invoke-ReleaseGit @('status', '--porcelain', '--', $manifestRelativePath))
if ($pending.Count) {
    Invoke-ReleaseGit @('diff', 'HEAD', '--', $manifestRelativePath)
    Invoke-ReleaseGit @('commit', '--only', '-m', ($commitMessageTemplate -f $Version), '--', $manifestRelativePath)
} else {
    Write-Host 'Manifest is already committed.'
}
Invoke-ReleaseGit @('push', $remoteName, "HEAD:refs/heads/$branch")
Write-Host "Release $tag verified and bucket manifest published to $remoteName/$branch."
