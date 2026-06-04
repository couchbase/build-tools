# check-new-releases

Keeps `scan-config.json` files up to date for the products which use
`get_source.sh` + `scan-config.json` (i.e. the non-manifest products scanned via
the blackduck-detect-trigger job), so new releases get Black Duck scans without
anyone having to remember to add them.

## How it works

For each directory under `blackduck/` containing both `scan-config.json` and
`get_source.sh`, the script:

1. Clones the **first** GitHub repo mentioned in `get_source.sh` (if the clone
   line isn't first, or clones the wrong repo first, pin the right one with a
   comment near the top, e.g. `# current repo, do not remove: github.com/couchbase/REPO`).
2. Finds the most recent *tagged* version in `scan-config.json` (entries with a
   `release` field, and literal `master`/`main` keys, point at branches and are
   ignored) and resolves its commit timestamp in the repo, reapplying the
   product's tag prefix if one is registered (see below).
3. Walks the repo's tags in chronological order:
   - tags older than that timestamp are skipped;
   - prerelease tags (e.g. `1.0.0-beta.1`) never match the version regex and are
     always skipped;
   - for each newer version tag: any existing version in the same major.minor
     series (compared semantically via `packaging.version`) is removed, and the
     new version is added with an interval of 1440;
   - the main branch is added as a version unless an entry with
     `release: master/main` already exists (prefer setting up the
     `snapshot` + `"release": "master"` pattern in `scan-config.json` up front so
     scans get a stable version label).
4. If the latest version in `scan-config.json` isn't tagged in the repo yet, it's
   assumed to be an upcoming release and nothing newer is considered.

Changes are written and staged as the script progresses.

## Onboarding a new product

For the checker to manage a new product's `scan-config.json`:

- Ensure the first `github.com` URL in `get_source.sh` is the repo to monitor
  (comment trick above if necessary).
- If the repo's release tags carry a prefix (`v1.2.3`, `java-client-3.11.2`),
  register it in the `tag_prefixes` dict in `check_new_releases.py`, keyed by the
  **directory** name. Tags with unregistered prefixes are invisible to the
  checker.
- If the product should NOT be auto-managed (e.g. only branches are scanned), add
  the directory name to the `ignorelist` in `check_new_releases.py`.

The checker only ever *adds* versions; retiring EOL major.minor series from
`scan-config.json` (to stay within the Black Duck scan quota) is a manual task.

## Running

`go.sh` requires a clean working tree (the script modifies and stages files in
place, and `--push` commits with `git commit -am`):

```
./go.sh             # run and report; leaves changes staged for inspection
./go.sh --dry-run   # run, show the diff that would be proposed, restore the tree
./go.sh --push      # commit and propose the changes to Gerrit
./go.sh --debug     # pass debug logging through to check_new_releases.py
```

Cloned repos land in `./build/` and can be deleted freely.
