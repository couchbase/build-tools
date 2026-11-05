#!/usr/bin/env python3

"""
Finds dependencies Black Duck silently dropped from a project-version's BOM,
and chooses a stand-in Knowledgebase version for each, so they still appear
in reports and notices.

Detect uploads every dependency it finds, but Black Duck leaves any whose
version isn't in the Knowledgebase out of the BOM, without any warning. A
dependency can't be added to the BOM in a version the Knowledgebase doesn't
know, so this adds a known version in its place.

It compares the dependencies in the uploaded BDIO with the origins in the
BOM. For each dropped one, it chooses a stand-in:

  - the fallback version from bd_aliases.yaml, matched exactly or by glob
    pattern (eg. "1.18.1-*"), if there is one
  - else the nearest lower release (not pre-release) version the
    Knowledgebase knows for that dependency

It logs each dropped dependency with its stand-in, or why it has none (eg. a
component the Knowledgebase doesn't know, or a Go pseudo-version), and with
--output also writes this as JSON.

With --manifest, it writes the stand-ins to a black-duck-manifest, leaving
out any the scan already matched. Run this before update-manual-manifest.py,
with the manifest under its --src-root, and it adds them to the BOM as
manually-added components.

A stand-in brings its own vulnerabilities into the BOM, which may not affect
the dependency's real version. With --bdsa, it checks each of them against
the affected version ranges of the related BDSA (Black Duck Security
Advisory), and reports those that likely don't. With --bdsa-stand-ins, it
also uses those ranges to choose the nearest lower version: of the closest
few, the one whose vulnerabilities best match the real version's. This works
whichever vulnerability source Black Duck shows by default, as each NVD
vulnerability links to its related BDSA.

blackduck-detect-scan.sh runs this after the scan completes, with
--bdsa-stand-ins, --output and --manifest. It only reads from Black Duck,
and is best effort: it never fails the scan.
"""

import argparse
import fnmatch
import io
import json
import logging
import pathlib
import re
import sys
import yaml
import zipfile

from bdhelper import BlackDuckClient
from concurrent.futures import ThreadPoolExecutor
from requests.adapters import HTTPAdapter
from urllib.parse import urlparse, quote


class DroppedComponentReporter:

    # Match a release version number, eg. "1.60.0", "v2.1" or "4.2.19.Final",
    # capturing its dotted numeric part
    release_re = re.compile(r"^v?([0-9]+(?:\.[0-9]+)*)(?:[.-][A-Za-z][A-Za-z0-9]*)?$")

    # Namespace used for the BDIO properties in Detect's scan data
    bdio_ns = "https://blackducksoftware.github.io/bdio#"

    # Number of dependencies to check against the Knowledgebase at once
    kb_threads = 16

    # Media type for full vulnerability records, including BDSA ranges
    vuln_media_type = "application/vnd.blackducksoftware.vulnerability-4+json"

    def __init__(self, credentials_file, project, version,
                 bdsa=False, bdsa_stand_ins=False):

        self.bdsa = bdsa or bdsa_stand_ins
        self.bdsa_stand_ins = bdsa_stand_ins

        with open(credentials_file, "r") as c:
            creds = json.load(c)
        self.client = BlackDuckClient(
            base_url=creds['url'],
            token=creds['token']
        )
        self.comp_base = self.client.resources['components'] + "/"

        # Keep a connection open for each Knowledgebase check thread, with
        # the client's usual retries
        adapter = self.client.session.get_adapter(creds['url'])
        self.client.session.mount("https://", HTTPAdapter(
            max_retries=adapter.max_retries, pool_maxsize=self.kb_threads
        ))

        logging.debug(f"Looking up project {project} version {version}")
        self.project_version = self.client.get_version_by_name(
            self.client.get_project_by_name(project), version
        )
        if self.project_version is None:
            raise RuntimeError(f"Project version {project} {version} not found")

        # Knowledgebase lookups cached across dependencies: component search
        # results keyed by <namespace>:<external ID>, and version names keyed by
        # <component_id>::<version prefix>
        self.kb_components = {}
        self.kb_versions = {}

        # Vulnerability lookups cached across dependencies: each stand-in
        # version's vulnerabilities keyed by its URL, and each BDSA's name and
        # affected ranges keyed by its URL
        self.version_vulns = {}
        self.bdsa_ranges = {}

        self._load_bd_aliases()


    def _load_bd_aliases(self):
        """
        Loads the component ID aliases and fallback versions from
        bd_aliases.yaml (see update-manual-manifest.py).
        """

        self.bd_comp_id_aliases = {}
        self.bd_comp_version_fallbacks = {}
        self.bd_comp_version_fallback_patterns = {}
        alias_filepath = pathlib.Path(__file__).resolve().parent / "bd_aliases.yaml"
        if not alias_filepath.exists():
            return
        with open(alias_filepath) as aliases_file:
            aliases = yaml.safe_load(aliases_file)
        for comp_id, comp_data in aliases.items():
            for alias_id in comp_data.get("bd-id-aliases", []):
                self.bd_comp_id_aliases[alias_id] = comp_id
            for version, fallback in comp_data.get("fallback-versions", {}).items():
                version = strip_v(str(version))
                if any(c in version for c in "*?["):
                    self.bd_comp_version_fallback_patterns.setdefault(
                        comp_id, []
                    ).append((version, str(fallback)))
                else:
                    self.bd_comp_version_fallbacks[
                        f"{comp_id}::{version}"
                    ] = str(fallback)


    def _get_fallback_version(self, comp_id, version):
        """
        Returns the bd_aliases.yaml fallback version for a component's version:
        that of an exact match, else of the first glob pattern it matches (eg.
        "1.18.1-*"), or None.
        """

        version = strip_v(version)
        fallback = self.bd_comp_version_fallbacks.get(f"{comp_id}::{version}")
        if fallback is not None:
            return fallback
        return next(
            (fallback for pattern, fallback
             in self.bd_comp_version_fallback_patterns.get(comp_id, [])
             if fnmatch.fnmatchcase(version, pattern)),
            None
        )


    def _get_declared_dependencies(self):
        """
        Returns the set of (namespace, external ID) pairs for every dependency
        Detect declared in this project-version's uploaded BDIO scan data, eg.
        ("maven", "com.azure:azure-core:1.60.0").
        """

        declared = set()
        for codelocation in self.client.get_resource(
            "codelocations", self.project_version
        ):
            links = {
                link["rel"]: link["href"]
                for link in codelocation["_meta"]["links"]
            }
            if "scan-data" not in links:
                continue
            response = self.client.session.get(links["scan-data"])
            # Raise rather than skip a code location that fails to download:
            # its dependencies would be missed, so their stand-ins would be
            # removed. With no manifest written, blackduck-detect-scan.sh
            # keeps them instead.
            response.raise_for_status()
            # Skip anything that isn't BDIO. Signature scans' scan data is
            # BDIO too, but declares no components, so it adds nothing.
            if "bdio" not in response.headers.get("Content-Type", ""):
                continue
            with zipfile.ZipFile(io.BytesIO(response.content)) as bdio:
                for entry in bdio.namelist():
                    if not (entry.startswith("bdio-entry")
                            and entry.endswith(".jsonld")):
                        continue
                    graph = json.loads(bdio.read(entry).decode("utf-8"))
                    for node in graph.get("@graph", []):
                        if self.bdio_ns + "Component" not in node.get("@type", []):
                            continue
                        namespace = node.get(
                            self.bdio_ns + "hasNamespace", [{}]
                        )[0].get("@value")
                        external_id = node.get(
                            self.bdio_ns + "hasIdentifier", [{}]
                        )[0].get("@value")
                        if namespace and external_id:
                            declared.add((namespace, external_id))

        return declared


    def _get_bom_origins(self):
        """
        Returns the set of (namespace, external ID) origins in the BOM.
        """

        origins = set()
        for comp in self.client.get_resource("components", self.project_version):
            for origin in comp.get("origins", []):
                origins.add(
                    (origin.get("externalNamespace"), origin.get("externalId"))
                )
        return origins


    def _search_knowledgebase(self, namespace, external_id):
        """
        Searches the Knowledgebase by external ID, eg. "maven" and
        "com.azure:azure-core:1.60.0", and returns the search results. Black
        Duck may file the result under a different external ID, eg.
        "cloud.google.com/go/iam:v1.5.3" as "cloud.google.com/go:iam/v1.5.3".
        """

        response = self.client.session.get(
            self.client.resources["components"],
            params={"q": f"{namespace}:{external_id}", "limit": 10}
        )
        response.raise_for_status()
        return response.json().get("items", [])


    def _find_known_version(self, namespace, external_id):
        """
        Returns the Knowledgebase's component-version search result for a
        versioned external ID, eg. "com.azure:azure-core:1.59.1", or None if
        it doesn't know that version. The search is fuzzy, eg. it may return
        1.59.10 for 1.59.1, so only a result for exactly that version counts.
        Its external ID may differ (see _search_knowledgebase()), but it must
        end in the same version, eg. "cloud.google.com/go:iam/v1.5.3" for
        "cloud.google.com/go/iam:v1.5.3". A Go pseudo-version's short commit
        hash, eg. "7de374b343fa", matches its full hash in the Knowledgebase.
        """

        wanted = strip_v(re.split(r"[:/]", external_id)[-1])
        is_hash = re.fullmatch(r"[0-9a-f]{7,40}", wanted) is not None
        for item in self._search_knowledgebase(namespace, external_id):
            if not item.get("version"):
                continue
            hit = item.get("originId") or item.get("versionName") or ""
            hit_version = strip_v(re.split(r"[:/]", hit)[-1])
            if hit_version == wanted or (
                is_hash and re.fullmatch(r"[0-9a-f]{40}", hit_version)
                and hit_version.startswith(wanted)
            ):
                return item
            logging.debug(
                f"Ignoring near-miss {hit} for {namespace}:{external_id}"
            )
        return None


    def _comp_id(self, item):
        """
        Returns a Knowledgebase search result's component ID, mapped through
        bd_aliases.yaml to the canonical ID.
        """

        comp_id = urlparse(item["component"]).path.rsplit("/", 1)[1]
        return self.bd_comp_id_aliases.get(comp_id, comp_id)


    def _find_component(self, namespace, external_id):
        """
        Returns the Knowledgebase's component search result for an unversioned
        external ID, eg. "com.azure:azure-core", or None. The search is fuzzy,
        so only a result with exactly that external ID counts.
        """

        # Keyed by namespace:external_id, pypi and npm packages can share a name
        key = f"{namespace}:{external_id}"
        if key not in self.kb_components:
            self.kb_components[key] = next(
                (item for item in self._search_knowledgebase(namespace, external_id)
                 if (item.get("originId") or "").lower() == external_id.lower()),
                None
            )
        return self.kb_components[key]


    def _find_component_version(self, comp_id, version):
        """
        Returns the Knowledgebase URL of the component's named version, or
        None if it doesn't have that version.
        """

        # The BD search API doesn't like some legit characters like +, but we
        # can use _ as a single-character wildcard
        safe_version = re.sub(r'[+]', '_', version)
        versions_url = (
            f"{self.comp_base}{comp_id}/versions"
            f"?q=versionName:{quote(safe_version)}&limit=100"
        )
        for v in self.client.get_json(versions_url).get("items", []):
            if strip_v(v["versionName"]) == strip_v(version):
                return v["_meta"]["href"]
        return None


    def _get_vulnerabilities(self, version_url):
        """
        Returns the vulnerabilities of a Knowledgebase component version, as
        a list of dicts: "name" (as the BOM shows it, eg. a CVE when NVD is
        the default source), "severity", and "bdsa-url" (the related BDSA's
        URL, or None if there isn't one).
        """

        if version_url not in self.version_vulns:
            vulns = []
            for item in self.client.get_items(f"{version_url}/vulnerabilities"):
                links = {
                    link["rel"]: link["href"]
                    for link in item["_meta"]["links"]
                }
                vulns.append({
                    "name": item["name"],
                    "severity": item.get("severity"),
                    "bdsa-url": item["_meta"]["href"]
                        if item.get("source") == "BDSA"
                        else links.get("related-affecting-vulnerability"),
                })
            self.version_vulns[version_url] = vulns
        return self.version_vulns[version_url]


    def _get_bdsa_ranges(self, bdsa_url):
        """
        Returns a BDSA's name and its affected version ranges, as a list of
        (component ID, first affected version, last affected version).
        """

        if bdsa_url not in self.bdsa_ranges:
            headers = {"Accept": self.vuln_media_type}
            bdsa = self.client.get_json(bdsa_url, headers=headers)
            links = {
                link["rel"]: link["href"]
                for link in bdsa["_meta"]["links"]
            }
            ranges = []
            if "bdsa-ranges" in links:
                for r in self.client.get_items(links["bdsa-ranges"], headers=headers):
                    comp_links = {
                        link["rel"]: link["href"]
                        for link in r["_meta"]["links"]
                    }
                    comp_id = urlparse(comp_links.get("component", "")).path.rsplit("/", 1)[-1]
                    ranges.append((
                        self.bd_comp_id_aliases.get(comp_id, comp_id),
                        r.get("versionStart"),
                        r.get("versionEnd")
                    ))
            self.bdsa_ranges[bdsa_url] = (bdsa["name"], ranges)
        return self.bdsa_ranges[bdsa_url]


    def _check_vulnerabilities(self, comp_id, version_url, real_version):
        """
        Checks each vulnerability of a stand-in version against the dependency's
        real version, using the related BDSA's affected ranges for the
        component. Returns a list of dicts: "name", "bdsa" (or None),
        "severity", and "status": "affected" if a range includes the real
        version, "stand-in only" if none does, or "unknown" if there's no
        BDSA, range or comparable version to go on.
        """

        real = version_key(real_version)
        results = []
        for vuln in self._get_vulnerabilities(version_url):
            result = {
                "name": vuln["name"],
                "bdsa": None,
                "severity": vuln["severity"],
                "status": "unknown",
            }
            results.append(result)
            if vuln["bdsa-url"] is None:
                continue
            result["bdsa"], ranges = self._get_bdsa_ranges(vuln["bdsa-url"])
            bounds = [
                (version_key(start), version_key(end))
                for range_comp_id, start, end in ranges
                if range_comp_id == comp_id
            ]
            bounds = [(s, e) for s, e in bounds if s is not None and e is not None]
            if real is None or not bounds:
                continue
            result["status"] = (
                "affected" if any(s <= real <= e for s, e in bounds)
                else "stand-in only"
            )
        return results


    def _best_bdsa_match(self, comp_id, candidates, version):
        """
        Given candidate stand-ins as (version name, version URL), highest
        first, returns the name of the one whose vulnerabilities best match
        the real version's, by BDSA ranges: the fewest that don't affect the
        real version, plus those affecting it that other candidates have but
        it lacks. Ties go to the highest version.
        """

        checked = [
            (name, self._check_vulnerabilities(comp_id, url, version))
            for name, url in candidates
        ]
        affecting = {
            v["name"] for _, vulns in checked for v in vulns
            if v["status"] == "affected"
        }

        def mismatches(vulns):
            stand_in_only = sum(1 for v in vulns if v["status"] == "stand-in only")
            has = {v["name"] for v in vulns if v["status"] == "affected"}
            return stand_in_only + len(affecting - has)

        # min() keeps the first, ie. highest, of equally good candidates
        return min(checked, key=lambda c: mismatches(c[1]))[0]


    def _find_nearest_lower_version(
        self, comp_name, comp_id, namespace, base, sep, version
    ):
        """
        Returns the Knowledgebase's name for the dependency's own version if
        the component has it, else for the highest release version lower than it,
        looking first for ones sharing more of its version number (eg. for 1.60.0,
        a 1.60.x version, then a 1.x one)  Candidates come from the component's
        versions, but each must also be known for the dependency's own external ID
        (base + sep + version): one component can cover several
        separately-versioned modules, eg. google-cloud-go.  With --bdsa-stand-ins,
        picks the best BDSA match of the highest few instead (see _best_bdsa_match()).
        Returns None if there is none.
        """

        match = self.release_re.match(version)
        if not match:
            return None
        wanted = [int(n) for n in match[1].split(".")]
        wanted_key = version_key(version)
        v_prefix = "v" if version.startswith("v") else ""

        for length in range(len(wanted) - 1, 0, -1):
            prefix = ".".join(str(n) for n in wanted[:length])
            key = f"{comp_id}::{prefix}"
            if key not in self.kb_versions:
                logging.debug(f"Searching for {comp_name} versions {prefix}.x")
                versions_url = (
                    f"{self.comp_base}{comp_id}/versions"
                    f"?q=versionName:{quote(prefix)}&limit=100"
                    f"&sort={quote('releasedOn DESC')}"
                )
                self.kb_versions[key] = [
                    v["versionName"] for v in
                    self.client.get_json(versions_url).get("items", [])
                ]

            candidates = []
            for name in self.kb_versions[key]:
                candidate = self.release_re.match(name)
                candidate_key = version_key(name)
                if not candidate or candidate_key is None:
                    continue
                exact = strip_v(name) == strip_v(version)
                numbers = [int(n) for n in candidate[1].split(".")]
                if exact or (
                    candidate_key[1] != 0
                    and numbers[:length] == wanted[:length]
                    and candidate_key < wanted_key
                ):
                    # Sort the exact version first, then the highest, and of
                    # equal versions, eg. 1.2.0 and 1.2.0.Final, the plain one
                    plain = re.fullmatch(r"v?[0-9]+(\.[0-9]+)*", name) is not None
                    candidates.append(((exact, candidate_key, plain), name))

            # Check the highest few against the dependency's own external ID
            known_candidates = []
            for (exact, _, _), name in sorted(candidates, reverse=True)[:5]:
                if v_prefix and not name.startswith("v"):
                    name = v_prefix + name
                known = self._find_known_version(namespace, f"{base}{sep}{name}")
                if known is not None and self._comp_id(known) == comp_id:
                    if exact or not self.bdsa_stand_ins:
                        return known["versionName"]
                    known_candidates.append(
                        (known["versionName"], known["version"])
                    )

            if known_candidates:
                return self._best_bdsa_match(comp_id, known_candidates, version)

        return None


    def _check_dependency(self, namespace, external_id):
        """
        Given a declared dependency with no matching origin in the BOM, returns
        None if Black Duck didn't drop it. Otherwise returns a dict describing
        it: "dependency", "component" and "bd-id" (None if the Knowledgebase
        doesn't know the component), "suggestion" (a stand-in version, or
        None) and "reason".
        """

        dependency = f"{namespace}:{external_id}"

        # Snapshots and Go modules replaced by local paths (eg. "../cbgt") are
        # our own code, not third-party releases
        if "SNAPSHOT" in external_id or external_id.startswith((".", "/")):
            logging.debug(f"Skipping {dependency}: not a third-party release")
            return None

        # Split off the version: "group:artifact:version" or "module:version",
        # else "name/version" (eg. pypi, npm)
        sep = ":" if ":" in external_id else "/"
        base, version = (
            external_id.rsplit(sep, 1) if sep in external_id else (None, None)
        )
        component = (
            self._find_component(namespace, base) if base is not None else None
        )
        comp_id = self._comp_id(component) if component is not None else None

        # If the Knowledgebase knows this exact version, pre-releases (eg.
        # v1.21.0-rc.0) included, Black Duck matched it, just under a
        # different origin, so it needs no stand-in. The search is fuzzy, so
        # the result must be for the dependency's own component, eg. not
        # com.foo:bar-extras:1.0.0 for com.foo:bar:1.0.0. Without a component
        # to compare, only a result for exactly this origin counts. Its
        # version has already been checked, and may be written differently,
        # eg. a Go pseudo-version's full commit hash, so compare without it.
        known = self._find_known_version(namespace, external_id)
        if known is not None:
            if comp_id is not None:
                matched = self._comp_id(known) == comp_id
            else:
                known_origin = known.get("originId") or ""
                matched = known_origin.lower() == external_id.lower() or (
                    base is not None and sep in known_origin
                    and known_origin.rsplit(sep, 1)[0].lower() == base.lower()
                )
            if matched:
                return None
            logging.debug(
                f"Ignoring {known.get('originId')} in "
                f"{known.get('componentName')}: not {dependency}'s component"
            )

        result = {
            "dependency": dependency,
            "component": None,
            "bd-id": None,
            "suggestion": None,
        }

        if base is None:
            result["reason"] = "no version in its external ID"
            return result
        if component is None:
            result["reason"] = "component not in the Knowledgebase"
            return result
        result["component"] = component["componentName"]
        result["bd-id"] = comp_id

        # Suggest the fallback version from bd_aliases.yaml if there is one,
        # else the nearest lower version
        fallback = self._get_fallback_version(comp_id, version)
        if fallback is not None:
            if self._find_component_version(comp_id, fallback) is not None:
                result["suggestion"] = fallback
                result["reason"] = "fallback version from bd_aliases.yaml"
            else:
                result["reason"] = (
                    f"bd_aliases.yaml fallback {fallback} isn't in the "
                    "Knowledgebase either"
                )
        elif not self.release_re.match(version):
            # eg. a Go pseudo-version, which has no "nearest" release
            result["reason"] = "not a release version"
        else:
            result["suggestion"] = self._find_nearest_lower_version(
                result["component"], comp_id, namespace, base, sep, version
            )
            result["reason"] = (
                "no earlier version in the Knowledgebase"
                if not result["suggestion"]
                else "same version, in the component's versions"
                if strip_v(result["suggestion"]) == strip_v(version)
                else "nearest lower version, best BDSA match"
                if self.bdsa_stand_ins
                else "nearest lower version"
            )

        # Check the stand-in's vulnerabilities against the real version
        if self.bdsa and result["suggestion"]:
            version_url = self._find_component_version(comp_id, result["suggestion"])
            if version_url is not None:
                result["vulnerabilities"] = self._check_vulnerabilities(
                    comp_id, version_url, version
                )

        return result


    def report(self):
        """
        Returns a list of report entries (see _check_dependency()) for the
        dependencies Black Duck dropped from the BOM, plus one with only
        "dependency" and "error" for each that couldn't be checked.
        """

        declared = self._get_declared_dependencies()
        missing = sorted(declared - self._get_bom_origins())
        logging.info(
            f"{len(missing)} of {len(declared)} declared dependencies have no "
            "matching origin in the BOM; checking the Knowledgebase"
        )

        def check(dependency):
            try:
                return self._check_dependency(*dependency)
            except Exception as e:
                logging.warning(
                    f"Could not check dependency {':'.join(dependency)}: {e}"
                )
                return {"dependency": ":".join(dependency), "error": str(e)}

        # Each check is a few Knowledgebase searches of about half a second,
        # so run them in parallel
        with ThreadPoolExecutor(max_workers=self.kb_threads) as executor:
            results = executor.map(check, missing)
            return [result for result in results if result is not None]


    def write_manifest(self, dropped, manifest_file):
        """
        Writes a black-duck-manifest listing each dropped dependency's
        suggested stand-in version, for update-manual-manifest.py to add to
        the BOM as a manually-added component. Leaves out stand-ins the scan
        already matched, which update-manual-manifest.py can't add again.
        Earlier scans' manually-added stand-ins don't count, as they must stay
        in the manifest or update-manual-manifest.py removes them.
        """

        scanned = {
            comp.get("componentVersion")
            for comp in self.client.get_resource("components", self.project_version)
            if set(comp.get("matchTypes", [])) - {"MANUAL_BOM_COMPONENT"}
        }

        components = {}
        for d in dropped:
            if not d["suggestion"]:
                continue
            stand_in = f"{d['component']} {d['suggestion']}"
            # Let a failed lookup raise: leaving the stand-in out would remove
            # it from the BOM
            version_url = self._find_component_version(
                d["bd-id"], d["suggestion"]
            )
            if version_url is None:
                logging.warning(f"Could not find {stand_in} in the Knowledgebase")
                continue
            if version_url in scanned:
                logging.info(f"{stand_in} is already in the BOM")
                continue
            logging.info(f"Listing {stand_in} for {d['dependency']}")
            comp = components.setdefault(
                d["component"], {"bd-id": d["bd-id"], "versions": []}
            )
            if d["suggestion"] not in comp["versions"]:
                comp["versions"].append(d["suggestion"])

        manifest_file = pathlib.Path(manifest_file)
        manifest_file.parent.mkdir(parents=True, exist_ok=True)
        tmp_file = manifest_file.with_name(manifest_file.name + ".tmp")
        with tmp_file.open("w") as f:
            f.write(
                "# Generated by stand-in-silently-dropped-components.py: stand-ins for\n"
                "# dependencies Black Duck dropped from the BOM\n"
            )
            yaml.safe_dump({"components": components}, f, sort_keys=False)
        tmp_file.replace(manifest_file)
        logging.info(
            f"Wrote {len(components)} stand-in components to {manifest_file}"
        )


def strip_v(version):
    """
    Strips any leading "v" from a version number, as update-manual-manifest.py
    does, eg. "v1.2.3" -> "1.2.3".
    """

    return re.sub(r"^v(?=[0-9])", "", version)


# Match a version number with an optional suffix, eg. "2.19.0-rc2", capturing
# its dotted numeric part and suffix; and a pre-release suffix, eg. "rc2",
# capturing its label and number. The label must be a whole word, so eg.
# "android" or "build1" isn't one, and "preview1" is "preview" 1, not "pre".
# Anything after the number must follow a "." or "-", eg. "beta.2.1" or
# "rc1-SNAPSHOT".
version_re = re.compile(r"^v?([0-9]+(?:\.[0-9]+)*)(?:[.-]?([A-Za-z][A-Za-z0-9.-]*))?$")
prerelease_re = re.compile(
    r"^(alpha|beta|a|b|rc|cr|m|milestone|pre|preview|dev)[.-]?([0-9]*)"
    r"(?:[.-].*)?$",
    re.IGNORECASE
)


def version_key(version):
    """
    Returns a key for comparing version numbers as BDSA ranges do, or None if
    it isn't one, eg. "2.19.0-rc2" < "2.19.0" == "2.19" == "2.19.0.Final" <
    "2.19.1". Pre-release suffixes sort before the release, others are
    ignored.
    """

    match = version_re.match(version or "")
    if not match:
        return None
    numbers = [int(n) for n in match[1].split(".")]
    while len(numbers) > 1 and numbers[-1] == 0:
        numbers.pop()
    pre = prerelease_re.match(match[2] or "")
    if pre:
        return (numbers, 0, pre[1].lower(), int(pre[2] or 0))
    return (numbers, 1, "", 0)


def log_report(project, version, dropped):
    """
    Logs the dropped dependencies, those with a suggested stand-in first,
    then any that couldn't be checked.
    """

    errors = [d for d in dropped if "error" in d]
    dropped = [d for d in dropped if "error" not in d]
    if errors:
        logging.warning(
            f"Could not check {len(errors)} dependencies:\n" + "\n".join(
                f"  {d['dependency']}  ({d['error']})" for d in errors
            )
        )

    if not dropped:
        logging.info(f"No dependencies were dropped from {project} {version}")
        return

    with_suggestion = [d for d in dropped if d["suggestion"]]
    without = [d for d in dropped if not d["suggestion"]]
    lines = [
        f"{len(dropped)} dependencies were silently dropped from the "
        f"{project} {version} BOM, because the Knowledgebase doesn't know "
        "their version:"
    ]
    if with_suggestion:
        lines.append("")
        lines.append(f"Added suggested stand-in ({len(with_suggestion)}):")
        for d in with_suggestion:
            lines.append(
                f"  {d['dependency']}\n"
                f"      -> {d['component']} {d['suggestion']} "
                f"({d['reason']}; bd-id {d['bd-id']})"
            )
            if "vulnerabilities" in d:
                lines.append(f"         {vulnerability_summary(d['vulnerabilities'])}")
    if without:
        lines.append("")
        lines.append(f"Without a suggested stand-in ({len(without)}):")
        for d in without:
            component = f"{d['component']}: " if d["component"] else ""
            lines.append(f"  {d['dependency']}  ({component}{d['reason']})")
    logging.warning("\n".join(lines))


def vulnerability_summary(vulns):
    """
    Summarises a stand-in's checked vulnerabilities (see
    _check_vulnerabilities()), naming those that likely don't affect the real
    version, eg. "BDSA: 2 of 5 stand-in vulnerabilities likely don't affect
    the real version: CVE-2026-91777 (BDSA-2026-32583), ...".
    """

    if not vulns:
        return "BDSA: stand-in has no vulnerabilities"
    stand_in_only = [v for v in vulns if v["status"] == "stand-in only"]
    unknown = sum(1 for v in vulns if v["status"] == "unknown")
    summary = (
        f"BDSA: {len(stand_in_only)} of {len(vulns)} stand-in vulnerabilities "
        "likely don't affect the real version"
    )
    if stand_in_only:
        names = [
            f"{v['name']} ({v['bdsa']})" if v["bdsa"] and v["bdsa"] != v["name"]
            else v["name"]
            for v in stand_in_only
        ]
        if len(names) > 10:
            names = names[:10] + [f"and {len(names) - 10} more"]
        summary += ": " + ", ".join(names)
    if unknown:
        summary += f"; {unknown} couldn't be checked"
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Find dependencies Black Duck silently dropped from the "
                    "BOM, and choose stand-in versions for them"
    )
    parser.add_argument('-d', '--debug', action='store_true',
        help="Produce debugging output")
    parser.add_argument('-c', '--credentials', required=True,
        help="Black Duck Hub credentials JSON file")
    parser.add_argument('-p', '--project', required=True,
        help="project from Black Duck server")
    parser.add_argument('-v', '--version', required=True,
        help="Version of <project>")
    parser.add_argument('-o', '--output',
        help="Also write the report to this file, as JSON")
    parser.add_argument('-m', '--manifest',
        help="Write a black-duck-manifest of the suggested stand-ins to this "
             "file, for update-manual-manifest.py to add to the BOM")
    parser.add_argument('--bdsa', action='store_true',
        help="Report which of each stand-in's vulnerabilities likely don't "
             "affect the real version, by BDSA affected ranges")
    parser.add_argument('--bdsa-stand-ins', action='store_true',
        help="Choose nearest lower stand-ins by how well their "
             "vulnerabilities match the real version's (implies --bdsa)")
    args = parser.parse_args()

    logging.basicConfig(
        stream=sys.stderr,
        format='%(threadName)s: %(asctime)s: %(levelname)s: %(message)s',
        level=logging.DEBUG if args.debug else logging.INFO
    )
    logging.getLogger("requests").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)

    # Best effort: never fail the scan
    try:
        reporter = DroppedComponentReporter(
            args.credentials, args.project, args.version,
            bdsa=args.bdsa, bdsa_stand_ins=args.bdsa_stand_ins
        )
        dropped = reporter.report()
    except Exception as e:
        logging.warning(f"Could not check for dropped dependencies: {e}")
        sys.exit(0)

    log_report(args.project, args.version, dropped)
    if args.output:
        with open(args.output, "w") as f:
            json.dump(dropped, f, indent=2)
    # Write no manifest if any dependency couldn't be checked: an incomplete
    # one would remove its stand-in, while with none, blackduck-detect-scan.sh
    # keeps every stand-in earlier scans added
    if args.manifest:
        if any("error" in d for d in dropped):
            logging.warning(
                "Not writing a stand-in manifest, as some dependencies "
                "couldn't be checked"
            )
        else:
            try:
                reporter.write_manifest(dropped, args.manifest)
            except Exception as e:
                logging.warning(f"Could not write stand-in manifest: {e}")
