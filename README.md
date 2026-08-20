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
bucket, the referenced tag must exist. PowerShell 7 and Git are required; Git
is used to read bucket history.

## Usage

```powershell
scoop chill                       # update eligible apps
scoop chill status                # show the decision for each app; writes nothing
scoop chill firefox -f            # update one app regardless of its age or hold
scoop chill -d                    # preview all writes without making them
scoop chill -n                    # skip the Scoop/bucket refresh

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

For a release, create and push a `v<version>` tag, then update `version`,
`url`, `hash`, and `extract_dir` in
[`bucket/scoop-chill.json`](bucket/scoop-chill.json). The manifest includes
`checkver` and `autoupdate` metadata for GitHub tags.
