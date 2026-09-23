# scoop-chill

`scoop chill` delays application updates until the corresponding bucket
manifest has been available for a configurable number of days. It is intended
to reduce exposure to freshly published, broken releases without giving up
Scoop's normal update workflow.

It is a Scoop command, not a replacement for `scoop update`: use `scoop chill`
when you want the age gate, and `scoop update` when you explicitly want Scoop's
normal immediate updates.

## Install

```powershell
scoop bucket add scoop-chill https://github.com/kroteau/scoop-chill
scoop install scoop-chill
```

Or install the manifest directly:

```powershell
scoop install https://raw.githubusercontent.com/kroteau/scoop-chill/main/bucket/scoop-chill.json
```

The release manifest downloads a tagged release archive. To install from a
bucket, the referenced tag must exist. PowerShell 5.1 or later and Git are
required; Git is used to read bucket history.

Scoop normally already provides Git for its buckets. If it is not available,
install either `git` or the SSH-enabled variant:

```powershell
scoop install git
# or
scoop install git-with-openssh
```

## Usage

```powershell
scoop chill                       # show the decision for each app; writes nothing
scoop chill *                     # update all eligible apps
scoop chill status                # show the decision for each app; writes nothing
scoop chill firefox -f            # update one app regardless of its age or hold
scoop chill * -d                  # preview all writes without making them
scoop chill firefox -n            # skip the Scoop/bucket refresh

scoop chill versions firefox      # show versions known to bucket history
scoop chill versions firefox -c 10
scoop chill pin firefox 141.0     # install this version after it has aged
scoop chill pin firefox           # select the next version after the installed one
scoop chill unpin firefox

scoop chill proxy set host:port   # set the proxy; use 'none' to clear it
scoop chill proxy add firefox     # use that proxy for this app's downloads
scoop chill proxy rm firefox

scoop chill reset                 # discard uncommitted changes in every bucket
scoop chill reset extras          # do so only in the extras bucket
```

`reset` runs `git reset --hard HEAD` and `git clean -fd` in affected bucket
directories. Review its output, or use `-d` first, before running it.

## How the gate works

For each outdated app (and for explicit pins), chill finds the first commit in
the installed bucket where the target version appeared. The app is eligible
once that commit is older than the configured age gate.

Before then, chill places a Scoop hold and records that it owns the hold. Holds
you created yourself are displayed as `ManualHold` and are never changed.
`--force` bypasses the gate for named apps. If a held version has been passed by
a newer manifest, chill pins the held version first, so releases are not
silently skipped.

Re-pushed versions (manifest changes without a version change) are hidden from
the normal report and blocked from updates, even after the age gate expires.
Chill remembers this block across runs; a newer version is evaluated normally.
Use `scoop chill go -Force` (also `-f` or `--force`) to allow a re-pushed update.
An explicit pin to a different version still follows its own age gate.

## Configuration and state

| Key | Default | Meaning |
| --- | ---: | --- |
| `chill_min_age_days` | 7 | Minimum age of a version before it may install. |
| `chill_refresh_max_age_hours` | 1 | Refresh Scoop and buckets once the previous refresh is this old. |

Set either setting through `scoop config`; for example:

```powershell
scoop config chill_min_age_days 14
```

Chill keeps its own state in `~\scoop\persist\scoop-chill`, including the last
refresh, holds it created, pins, and proxy choices. The proxy address uses
Scoop's `[user:pass@]host:port` form. Because this state is stored locally,
avoid putting long-lived credentials in the proxy URL when possible.

## Development

Run the test suite with:

```powershell
.\chill.tests.ps1
```

The re-push integration test creates a temporary Git bucket and state directory.
It checks the normal report/update flow with no prior package state, a repeated
run, and forced updates. Scoop installation and update calls are mocked, so it
does not modify installed packages.

For a release, commit your changes, then run:

```powershell
.\release.ps1 0.0.7
```

Add `-WhatIf` to preview the remaining steps. It reads local state and queries
remote tags, but does not fetch, run tests, download archives, or change files.
Checks requiring a missing local tag or an archive download are deferred.

The script discovers and runs root-level `chill*.tests.ps1` files in name order,
creates and pushes the tag, and updates the manifest using that exact version.
It verifies the manifest against the downloaded archive, commits only the manifest,
and pushes the current branch to the same branch name on the configured remote.
Unrelated staged and unstaged files are left alone; existing commits on that branch
are included in the push. Use `-WhatIf` to preview before publishing.

Rerun the same command to resume: existing tags are reused, conflicting tags are
rejected, and an already correct manifest is left alone. New tags require a clean
working tree. When resuming, README, release script, and manifest edits are allowed;
the remaining tracked files must match the tag. Published tags are never moved.
If the branch push fails, rerunning retries it without duplicating the manifest
commit. Diverged branches require reconciliation; the script never force-pushes.

Use your next release version in place of `0.0.7`. `checkver` reads published
GitHub tags; no GitHub release is required. Local-only tags are not visible to
it, and their archives cannot be downloaded to calculate the hash.

The command updates `version`, `url`, `hash`, and `extract_dir` together.
The release tag stays on the tested commit, before the manifest commit.
When using `checkver` directly, commit and push the manifest yourself.
To target a particular published tag, add `-Version 0.0.7`
(without the `v`) to the `checkver` command.
