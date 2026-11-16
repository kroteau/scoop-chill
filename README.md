# scoop-chill

`scoop chill` delays an app's update until chill has known about the new
version for a set number of days (7 by default). It is intended to reduce
exposure to freshly published, broken releases without giving up Scoop's
normal update workflow.

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
scoop chill                       # show the decision for each app; records new versions
scoop chill *                     # update all eligible apps
scoop chill status                # show the decision for each app; records new versions
scoop chill firefox -f            # update one app regardless of its age or hold
scoop chill claude-code@2.1.280    # update to an exact version from bucket history
scoop chill claude-code@2.1.280 -f # bypass the target version's age gate and holds
scoop chill * -d                  # preview all writes without making them
scoop chill firefox -n            # skip the Scoop/bucket refresh

scoop chill versions firefox      # show versions known to bucket history
scoop chill versions firefox -c 10

scoop chill proxy set host:port   # set the proxy; use 'none' to clear it
scoop chill proxy add firefox     # use that proxy for this app's downloads
scoop chill proxy rm firefox

scoop chill reset                 # discard uncommitted changes in every bucket
scoop chill reset extras          # do so only in the extras bucket
```

`reset` runs `git reset --hard HEAD` and `git clean -fd` in affected bucket
directories. Review its output, or use `-d` first, before running it.

## How the gate works

`<app>@<version>` selects the newest manifest from that version's most recent
run in the installed bucket's Git history, gated on when chill first saw it.
The target's age gate and manual holds still apply unless `-f` is used;
upgrades and downgrades are supported. An already-installed target is a no-op,
including with `-f`. Unknown versions and URL-installed apps are skipped with a
warning.

This target applies only to the current invocation; later ordinary updates
resume the normal age gate. The bucket manifest is restored after the update; a
manifest with local changes is left untouched.

Every outdated app updates in series, never straight to latest. Chill walks the
installed bucket's Git history back to the installed version and takes the
newest version chill first saw longer ago than the configured age gate. If
1.1, 1.2 and 1.3 have aged and 1.4 has not, an app at 1.0 goes to 1.3; 1.4
follows once it has aged too. When the installed version is missing from
history, only latest is considered.

A version's age is counted from the run that first saw it, never from a Git
date: a commit's author sets those, and can backdate them. Every run records
the versions it sees for the first time, `status` and `scoop chill` alone
included; `-d` shows such a version at age 0 and records nothing. A version
chill has never seen counts as seen now, including on first use, after adding
a bucket, and after upgrading from a release without this record: everything
outstanding then waits the age gate once.

The report reads left to right:

| Column | Meaning |
| --- | --- |
| `Latest`, `Published` | The bucket's latest version and the date its first commit claims; for reference only. |
| `Target`, `Indexed` | The version this run would install and the day chill first saw it. |
| `Age` | Days since `Indexed`; this is what the age gate compares. |
| `Action` | `Ready`, `Held`, `ManualHold`, `Forced`, `Current` or `Failed`. |

`Target` is the step, an `app@version` target, or latest under `-f`. It carries
`(-N)` for the versions still newer than it; `(?)` means history does not know
it. `Action` carries `^` for an app routed through the proxy.

Until a version has aged, chill places a Scoop hold and records that it owns the
hold. An app left short of latest, by a step or by an update that did not land,
is held again afterwards, so a plain `scoop update` cannot jump it ahead. Holds
you created yourself are displayed as `ManualHold` and are never changed.
`--force` installs latest for named apps, regardless of the gate; a manual hold
it overrides is put back afterwards, whether the update succeeded or not. To keep
an app at its version, hold it with `scoop hold`.

Chill's state records only what has happened: the holds it owns, proxy
choices, and when it first saw each version it may install. Versions are read
from history on every run, so a run that is held or fails cannot make chill
forget a version that is due.

A version is gated on when chill first saw it, and installs from its
newest manifest. Any later change to that manifest without a version change is
warned about. Some changes touch what gets installed or run: `url`, `hash`,
`extract_dir`, `extract_to`, `innosetup`, `depends`, `bin`, `shortcuts`,
`persist`, `psmodule`, `env_add_path`, `env_set`, `installer`, `uninstaller`,
or a `pre_`/`post_` install or uninstall script, at the top level or for an
architecture. Updates skip a version with such a change, and keep warning with
the fields that changed, until a newer version passes the age gate; naming the
app does not change that. Naming the version, as in
`scoop chill llmfit@1.1.18`, takes the changed manifest. Every run warns about
the manifest it chose when that is not simply an aged release: a changed
install, an edited manifest, or what `-f` bypassed.

### Installing an older manifest of a version

Chill always takes a version's newest manifest. To install an earlier one, for
example the download a later commit replaced, restore it in the bucket by hand,
update, and put the bucket back:

```powershell
$bucket = "$env:USERPROFILE\scoop\buckets\main"
git -C $bucket log --format='%h %ad %s' --date=short -- bucket/llmfit.json
git -C $bucket restore --source <hash> -- bucket/llmfit.json
scoop unhold llmfit        # only if it is held; chill holds it again if needed
scoop update llmfit -f
git -C $bucket restore -- bucket/llmfit.json
```

`git restore` writes the manifest byte for byte, so no shell encoding gets in
the way. A bucket left modified is reported by `scoop chill reset -d`.

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
refresh, holds it created, proxy choices, and when it first saw each version.
Deleting an app's state file makes every version it may install wait the age
gate again. The proxy address uses Scoop's `[user:pass@]host:port` form. The
address, password included, is stored in plain text in `_scoop_chill.json`,
so prefer a proxy account without other uses.

## Development

Run the test suite with:

```powershell
.\chill.tests.ps1
```

The integration tests create temporary Git buckets and state directories. They
check series updates, rewritten manifests, held and incomplete runs, and forced
updates. Scoop installation and update calls are mocked, so they do not modify
installed packages.

To run the working copy against your real Scoop install, without installing it,
define a helper in your session or profile:

```powershell
$core = "$env:USERPROFILE\scoop\apps\scoop\current"
$repo = 'C:\path\to\scoop-chill'
function chill-dev { pwsh -NoProfile -Command "`$coreRoot = '$core'; . '$core\lib\core.ps1'; . '$core\lib\buckets.ps1'; & '$repo\scoop-chill.ps1' $args" }
```

`chill-dev status` changes no apps, but records newly seen versions in your real
state. Anything else acts on your real apps and state, just as `scoop chill`
would: preview with `chill-dev * -d` first.

For a release, commit your changes, then run:

```powershell
.\release.ps1 0.0.7
```

Add `-WhatIf` to preview the remaining steps. It reads local state and queries
remote tags, but does not fetch, run tests, download archives, or change files.
Checks requiring a missing local tag or an archive download are deferred.

The script discovers and runs root-level `chill*.tests.ps1` files in name
order, creates and pushes the tag, and updates the manifest using that exact
version. It verifies the manifest against the downloaded archive, commits only
the manifest, and pushes the current branch to the same branch name on the
configured remote. Unrelated staged and unstaged files are left alone;
existing commits on that branch are included in the push.

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
