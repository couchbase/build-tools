# import_govulncheck.py

Uploads the govulncheck reports written by the tlm `go-vulncheck` target
(`<build>/govulncheck/*.json`, where `<build>` is the CMake build
directory) to DefectDojo, one test per Go program.

```
DD_URL=https://defectdojo.example.com DD_API_KEY=... \
  ./import_govulncheck.py --report-dir <build>/govulncheck \
    --product-type couchbase-server --product couchbase-server \
    --version 8.0.0
```

Each version gets its own DefectDojo engagement, and each new build of
that version re-imports into it, replacing the previous build's results.

Run `./import_govulncheck.py --help` for all options.

Each report is filtered to the advisories that affect the program
(filtered copies go to `<build>/govulncheck-filtered/`) and uploaded with
DefectDojo's Govulncheck parser, which marks every finding Info.

The script then sets each finding's severity from the advisory's GHSA
(osv.dev) or CVE (cve.org) score, raised one level if the vulnerable function
is present in the binary. Advisories with no score are set to Info and
tagged `unscored`. The source of each severity, with a link, is recorded
in the finding's severity justification. This runs after every upload, so
changes are picked up. `--no-severity` skips it.

Two sources are needed because the Go vulnerability database has no
scores. osv.dev gives each Go advisory's GHSA and CVE aliases, and the
GHSA score, which most advisories have. cve.org is only asked for
advisories with no scored GHSA alias, since it has the CVE scores but
doesn't know Go advisory IDs. cve.org is used rather than NVD as it gets
the CNA's and CISA's scores first, and has no rate limit.
