#!/usr/bin/env -S uv run

# /// script
# dependencies = [
#   "requests"
# ]
# [tool.uv]
# exclude-newer = "2026-10-12T00:00:00Z"
# ///

"""
Import govulncheck JSON reports (as produced by the tlm 'go-vulncheck'
target) into DefectDojo, one test per Go program.

Before uploading, each report is filtered to drop advisories which have
no matching finding, as DefectDojo's Govulncheck parser otherwise turns
every advisory for every module in the binary into a finding.

The Go vulnerability database has no severity, so after uploading, the
severity of each finding is set from the advisory's GHSA alias (via
osv.dev) or its CVE (via cve.org), raised one level if the vulnerable
function is present in the binary. Advisories with no score are set to
Info and tagged 'unscored'. Where each severity came from is recorded in
the finding's severity justification.
"""

import argparse
import datetime
import functools
import json
import logging
import os
import pathlib
import re
import sys

import requests

LEVELS = ["Info", "Low", "Medium", "High", "Critical"]
LABELS = {"LOW": "Low", "MODERATE": "Medium", "MEDIUM": "Medium",
          "HIGH": "High", "CRITICAL": "Critical"}
REACH_ORDER = ["module", "imported", "called"]
UNSCORED_TAG = "unscored"
SOURCE_URLS = {"GHSA": "https://github.com/advisories/{}",
               "CVE": "https://www.cve.org/CVERecord?id={}"}
SCAN_TYPE = "Govulncheck Scanner"
OSV_URL = "https://api.osv.dev/v1/vulns"
CVE_ORG_URL = "https://cveawg.mitre.org/api/cve"

logger = logging.getLogger(__name__)


def read_stream(path):
    """
    govulncheck -format json writes a stream of JSON objects rather
    than a single JSON document. Return them as a list.
    """
    text = path.read_text()
    decoder = json.JSONDecoder()
    objs, i = [], 0

    while True:
        while i < len(text) and text[i].isspace():
            i += 1

        if i >= len(text):
            return objs

        obj, i = decoder.raw_decode(text, i)
        objs.append(obj)


def filter_report(objs):
    """
    Drop 'osv' records with no matching 'finding'. Returns the filtered
    objects and a dict of {GO id: reachability} for this program.
    """

    # reach: {GO id: "called" | "imported" | "module"} - how close this
    # program gets to each advisory that affects it, keeping the closest
    # if an advisory has several findings. Used later to set severity.
    # In binary mode, govulncheck's symbol level means the vulnerable
    # function is compiled into the binary, not a traced call path.
    reach = {}
    for obj in objs:
        if "finding" not in obj:
            continue

        finding = obj["finding"]
        top = finding["trace"][0]
        level = ("called" if top.get("function")
                 else "imported" if top.get("package") else "module")
        current = reach.get(finding["osv"], "module")

        if REACH_ORDER.index(level) >= REACH_ORDER.index(current):
            reach[finding["osv"]] = level

    # kept: the report to upload - every object except 'osv' advisories
    # with no finding, ie. ones the version in use isn't affected by.
    kept = [obj for obj in objs
            if "osv" not in obj or obj["osv"]["id"] in reach]

    return kept, reach


session = requests.Session()


def get_json(url, **kwargs):
    """Fetch JSON; return {} (with a warning) if the request fails."""
    try:
        resp = session.get(url, timeout=30, **kwargs)
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as e:
        logger.warning(f"Lookup failed: {url} ({e})")
        return {}


def ghsa_severity(ghsa_id):
    """Severity of a GitHub advisory, from osv.dev, or None."""
    sev = get_json(f"{OSV_URL}/{ghsa_id}") \
        .get("database_specific", {}).get("severity")
    return LABELS.get(sev)


def cve_severity(cve_id):
    """
    Newest CVSS severity of a CVE, from cve.org, or None. cve.org has
    the CNA's and CISA's scores as soon as they're published; NVD only
    copies them later.
    """
    containers = get_json(f"{CVE_ORG_URL}/{cve_id}").get("containers", {})
    found = []
    for container in [containers.get("cna", {})] + containers.get("adp", []):
        for metric in container.get("metrics", []):
            # Keys look like cvssV4_0, cvssV3_1; CNA wins a tie
            for key, data in metric.items():
                version = re.fullmatch(r"cvssV(\d+)_(\d+)", key)
                if not version:
                    continue
                sev = LABELS.get(data.get("baseSeverity"))
                if sev:
                    found.append((tuple(map(int, version.groups())), sev))
    found.sort(key=lambda f: f[0], reverse=True)
    return found[0][1] if found else None


@functools.cache
def advisory_score(go_id):
    """
    Return (severity, source) for a GO advisory: from a GHSA alias if
    possible, else from a CVE alias, else (None, None).
    """
    aliases = get_json(f"{OSV_URL}/{go_id}").get("aliases", [])
    lookups = [(a, ghsa_severity) for a in aliases if a.startswith("GHSA-")]
    lookups += [(a, cve_severity) for a in aliases if a.startswith("CVE-")]
    for alias, lookup in lookups:
        sev = lookup(alias)
        if sev:
            logger.info(f"{go_id}: {sev} ({alias})")
            return sev, alias
    logger.info(f"{go_id}: no score")
    return None, None


def severity_for(go_id, reach):
    """
    Return (severity, justification) for an advisory: its score, raised
    one level if the vulnerable function is present in the binary, or
    Info if it has no score.
    """
    score, source = advisory_score(go_id)
    if score is None:
        return "Info", f"No GHSA or CVE score found (reachability: {reach})"

    url = SOURCE_URLS[source.split("-")[0]].format(source)
    justification = f"{score} from {source} ({url})"
    if reach != "called":
        return score, justification

    severity = LEVELS[min(LEVELS.index(score) + 1, len(LEVELS) - 1)]
    if severity != score:
        justification += (f", raised to {severity} as the vulnerable "
                          "function is present in the binary")
    return severity, justification


class DefectDojo:
    def __init__(self, url, api_key):
        self.api = url.rstrip("/") + "/api/v2"
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Token {api_key}"

    def reimport(self, path, args, program):
        """Upload one filtered report, creating the test if needed."""
        data = {
            "scan_type": SCAN_TYPE,
            "auto_create_context": "true",
            "product_type_name": args.product_type,
            "product_name": args.product,
            "engagement_name": args.version,
            "test_title": program,
            "scan_date": args.scan_date,
            "active": "true",
            "verified": "false",
            "close_old_findings": "true",
        }
        with path.open("rb") as f:
            resp = self.session.post(f"{self.api}/reimport-scan/",
                                     data=data, files={"file": f},
                                     timeout=300)
        resp.raise_for_status()
        return resp.json()["test"]

    def active_findings(self, test_id):
        url = f"{self.api}/findings/"
        params = {"test": test_id, "active": "true", "limit": 500}
        while url:
            resp = self.session.get(url, params=params, timeout=60)
            resp.raise_for_status()
            page = resp.json()
            yield from page["results"]
            url, params = page.get("next"), None

    def update_finding(self, finding_id, fields):
        resp = self.session.patch(f"{self.api}/findings/{finding_id}/",
                                  json=fields, timeout=60)
        resp.raise_for_status()


def parse_args():
    parser = argparse.ArgumentParser(
        description="Import govulncheck JSON reports into DefectDojo")
    parser.add_argument("--report-dir", required=True, type=pathlib.Path,
                        help="Folder of govulncheck JSON files "
                             "(eg. <build>/govulncheck)")
    parser.add_argument("--version", required=True,
                        help="Product version, eg. 8.0.0; used as the "
                             "DefectDojo engagement name")
    parser.add_argument("--product", required=True,
                        help="DefectDojo product name, eg. couchbase-server")
    parser.add_argument("--product-type", required=True,
                        help="DefectDojo product type name, "
                             "eg. couchbase-server")
    parser.add_argument("--scan-date",
                        default=datetime.date.today().isoformat(),
                        help="Scan date (YYYY-MM-DD), default today")
    parser.add_argument("--no-severity", action="store_true",
                        help="Don't look up and set severities")
    parser.add_argument("--dry-run", action="store_true",
                        help="Filter and summarise reports only; "
                             "don't upload")
    parser.add_argument("--debug", action="store_true",
                        help="Enable debug output")
    return parser.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(
        format="%(levelname)s: %(message)s", stream=sys.stderr,
        level=logging.DEBUG if args.debug else logging.INFO)

    reports = sorted(args.report_dir.glob("*.json"))
    if not reports:
        logger.error(f"No JSON reports found in {args.report_dir}")
        sys.exit(1)

    dojo = None
    if not args.dry_run:
        url, key = os.environ.get("DD_URL"), os.environ.get("DD_API_KEY")
        if not url or not key:
            logger.error("DD_URL and DD_API_KEY must be set")
            sys.exit(1)
        dojo = DefectDojo(url, key)

    outdir = args.report_dir.parent / "govulncheck-filtered"
    if dojo is not None:
        outdir.mkdir(exist_ok=True)

    tests = {}     # test id -> program
    reaches = {}   # program -> {GO id: reachability}
    aliases = {}   # GO id -> [GHSA / CVE ids]
    failed = []
    for report in reports:
        program = report.stem
        kept, reach = filter_report(read_stream(report))
        reaches[program] = reach
        aliases.update((o["osv"]["id"], o["osv"].get("aliases") or [])
                       for o in kept if "osv" in o)
        called = sum(1 for r in reach.values() if r == "called")
        print(f"{program} advisories={len(reach)} called={called}")
        if dojo is None:
            continue
        filtered = outdir / report.name
        filtered.write_text("\n".join(json.dumps(o) for o in kept) + "\n")
        try:
            tests[dojo.reimport(filtered, args, program)] = program
        except requests.RequestException as e:
            logger.error(f"Upload failed for {program}: {e}")
            failed.append(program)

    all_ids = {i for reach in reaches.values() for i in reach}
    print(f"\n{len(reports)} programs, {len(all_ids)} distinct advisories")

    if dojo is not None and not args.no_severity:
        counts = {}
        for test_id, program in tests.items():
            for finding in dojo.active_findings(test_id):
                go_id = (finding.get("unique_id_from_tool")
                         or finding["title"].split(" ")[0])
                reach = reaches[program].get(go_id, "module")
                severity, justification = severity_for(go_id, reach)

                # Add or remove the 'unscored' tag, keeping any others
                tags = set(finding.get("tags") or []) - {UNSCORED_TAG}
                if advisory_score(go_id)[0] is None:
                    tags.add(UNSCORED_TAG)

                # Re-import clears the vulnerability IDs of existing
                # findings, as the parser only sets the legacy 'cve'
                # field, so set them from the advisory's aliases
                vuln_ids = [{"vulnerability_id": a}
                            for a in aliases.get(go_id, [])]

                fields = {"severity": severity,
                          "severity_justification": justification,
                          "tags": sorted(tags),
                          "vulnerability_ids": vuln_ids}
                if any(finding.get(k) != v for k, v in fields.items()):
                    dojo.update_finding(finding["id"], fields)
                counts[severity] = counts.get(severity, 0) + 1
        print("Findings by severity:",
              ", ".join(f"{s}={counts[s]}" for s in reversed(LEVELS)
                        if s in counts))

    if failed:
        logger.error(f"Upload failed for: {', '.join(failed)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
