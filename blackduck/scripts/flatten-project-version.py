#!/usr/bin/env python3

import argparse
import csv
import json
import logging
import pprint
import requests
import sys
import time

from blackduck import Client
from urllib.parse import urlparse

class BlackDuckFlatten:
    """
    Given a Black Duck project and version, replace all "scanned from source code"
    components with identical "manually added" components
    """

    def __init__(self, url, token, project, version, dryrun):
        self.dryrun = dryrun
        logging.info(f"Preparing to flatten components for {project} {version}")
        self.bd = Client(base_url=url, token=token, verify=False)

        # Save Black Duck's data about the project-version
        self.project = project
        self.project_ver = version
        logging.debug(f"Looking up project {project}")
        self.proj_data = self._get_resource_by_name("projects", project)
        logging.debug(f"Project is {pprint.pformat(self.proj_data)}")
        logging.debug(f"Looking up project version {version}")
        self.proj_ver_data = self._get_resource_by_name(
            "versions", version, parent=self.proj_data, key="versionName"
        )
        logging.debug(f"Project-version is {pprint.pformat(self.proj_ver_data)}")
        logging.debug(f"available resources are {pprint.pformat(self.bd.list_resources(self.proj_ver_data))}")
        pv_components_url = self.bd.list_resources(self.proj_ver_data)["components"]
        self.pv_components_url = urlparse(pv_components_url).path
        logging.debug(f"Project-version components URL is {self.pv_components_url}")


    def _get_resource_by_name(self, resource, name, parent=None, key="name"):
        """
        Convenience function to retrieve a single child resource by name,
        or optionally by some key other than 'name'
        """

        result = self.bd.get_resource(
            resource,
            parent=parent,
            params={'q':[f'{key}:{name}']},
            items=False,
        )
        # The Black Duck API only does a substring match, so we need to
        # dig through the results to find the one we want
        for result in result["items"]:
            if result[key] == name:
                return result
        logging.fatal(f"Did not find {resource} {key}:{name}!")
        sys.exit(2)


    def read_scan_components(self):
        """
        Discovers all components associated with the project-version
        that originate from a signature scan. Returns a tuple of:
          * list of component dicts with keys "uri", "name", "version".
          * set of scan hrefs
        """

        components = []
        scan_hrefs = set()
        for component in self.bd.get_resource(
            "components",
            parent=self.proj_ver_data,
            params = {
                "filter": [
                    "bomMatchType:file_exact",
                    "bomMatchType:files_exact",
                    "bomMatchType:files_modified",
                    "bomMatchType:files_added_deleted",
                    "bomMatchType:manually_identified",
                ]
            }
        ):
            # Identify the scans associated with any matched files for
            # this component
            for match in self.bd.get_resource("matched-files", parent=component):
                scan_hrefs.add(self.bd.list_resources(match)["codelocations"])

            # Remember everything about the component
            entry = {
                "name": component["componentName"],
                "version": component.get("componentVersionName", "<none>"),
                "uri": component.get("componentVersion", component["component"]),
            }
            components.append(entry)
            logging.debug(f"Found component {entry['name']} version {entry['version']}")

        logging.debug(f"Found {len(components)} components in {len(scan_hrefs)} signature scan(s)")

        return (components, scan_hrefs)


    def delete_signature_scans(self):
        """
        Finds any signature-scan code locations and removes them from the project-version
        """

        # Find all signature-scan scans for this project-version, and
        # delete them
        (components, scan_hrefs) = self.read_scan_components()
        for scan in scan_hrefs:
            logging.info(f"Deleting scan {scan}")
            if self.dryrun:
                logging.info("DRYRUN: not updating Black Duck")
                continue

            response = self.bd.session.delete(scan)
            response.raise_for_status()

        if self.dryrun:
            return

        # Verify that the project-version now has no components from signature scan
        while True:
            time.sleep(5)
            (components, _) = self.read_scan_components()
            if len(components) == 0:
                logging.info("Verified 0 signature scan components after deleting scan(s)!")
                break
            logging.info("There are still signature scan components, waiting...")


    def add_manual_component(self, comp_name, comp_version, comp_id, version_id):
        """
        Adds a component-version to this project-version.
        """

        logging.info(f"Adding component: {comp_name} version {comp_version}")

        if self.dryrun:
            logging.info("DRYRUN: not updating Black Duck")

        else:
            post_data = {
                'component': f"https://blackduck.build.couchbase.com/api/components/{comp_id}/versions/{version_id}"
            }
            try:
                response = self.bd.session.post(self.pv_components_url, json=post_data)
                response.raise_for_status()
            except requests.HTTPError as ee:
                err = ee.response.json()
                if err['errorCode'] == '{manual.bom.view.entry.already.exists}':
                    logging.warning(f"{comp_name} {comp_version} already exists in project-version")
                else:
                    logging.fatal(err)
                    sys.exit(5)

            logging.debug(f"{comp_name} version {comp_version} added successfully")


    def add_manual_components(self):
        """
        Load the most recent components.csv report, and add new manual
        components for any components previously derived from a
        signature scan
        """

        # Download existing scan components
        csv_url = (
            f"https://raw.githubusercontent.com/couchbase/product-metadata/"
            f"master/{self.project}/blackduck/{self.project_ver}/components.csv"
        )
        logging.info(f"Reading components.csv for {self.project} {self.project_ver}")
        logging.debug(f"from URL: {csv_url}")
        with requests.get(csv_url, stream=True) as r:
            components = csv.DictReader(line.decode('utf-8') for line in r.iter_lines())

            for comp in components:
                match_types = comp['Match type'].split(',')
                # Only need a new manual entry for any component-version
                # that *only* came from signature scans in the past
                if all(
                    m in (
                        "Exact",
                        "Files Modified",
                        "Files Added/Deleted"
                    ) for m in match_types
                ):
                    self.add_manual_component(
                        comp['Component name'],
                        comp['Component version name'],
                        comp['Component id'],
                        comp['Version id']
                    )


    def flatten(self):
        """
        Flattens all components
        """

        # Need to detach the scan results first, or else certain components
        # (those with no origins, for whatever reason) will fail with a
        # "cannot add to BOM because it already exists" error.
        self.delete_signature_scans()

        # Read CSV report and add new manual components
        self.add_manual_components()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Get components from hub"
    )
    parser.add_argument('-d', '--debug', action='store_true',
        help="Produce debugging output")
    parser.add_argument('-r', '--credentials', required=True,
        type=argparse.FileType('r'),
        help="File containing Black Duck Hub credentials")
    parser.add_argument('-p', '--project', required=True,
        help="project from Black Duck server")
    parser.add_argument('-v', '--version', required=True,
        help="Version of <project>")
    parser.add_argument('-n', '--dryrun', action='store_true',
        help="Dry run - don't update Black Duck, just report actions")
    args = parser.parse_args()

    if args.debug:
        log_level = logging.DEBUG
    else:
        log_level = logging.INFO

    logging.basicConfig(
        stream=sys.stderr,
        format='%(threadName)s: %(asctime)s: %(levelname)s: %(message)s',
        level=log_level
    )
    logging.getLogger("requests").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)

    creds = json.load(args.credentials)
    flattener = BlackDuckFlatten(
        creds["url"],
        creds["token"],
        args.project,
        args.version,
        args.dryrun
    )
    flattener.flatten()
