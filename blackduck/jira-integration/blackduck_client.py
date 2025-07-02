#!/usr/bin/env python3

import sys
import json
import logging
from collections import defaultdict
from pathlib import Path
from itertools import groupby
import urllib
from blackduck import Client
import constants

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)


class BlackduckClient:
    def __init__(self):
        '''
        Initiate Black Duck connection.
        '''
        creds_file = Path.home() / '.ssh/blackduck-creds.json'
        if creds_file.exists():
            with open(creds_file) as f:
                bd_creds = json.load(f)
        else:
            logging.error('Unable to locate blackduck-creds.json')
            sys.exit(1)

        self.base_url = bd_creds['url']
        self.hub_client = Client(
            token=bd_creds['token'],
            base_url=bd_creds['url'],
            verify=True,
            timeout=30.0,
            retries=5
        )

    def _get_resource_by_name(self, key, resource_type,
                              resource_name, parent=None):
        '''Helper function to query and return single resource by name'''
        params = {
            'q': [f"{key}:{resource_name}"]
        }
        result = [r for r in self.hub_client.get_resource(
            resource_type,
            parent=parent,
            params=params)
            if r[key] == resource_name]
        if len(result) != 1:
            raise ValueError(
                f"Expected one {resource_type} of {resource_name}, but found {len(result)}")
        return result[0]

    def _fetch_all_links(self, url, headers=None):
        '''Helper function to fetch paginated data from the given URL,'''
        all_items = []
        while url:
            result = self.hub_client.get_json(url, headers=headers)
            # Add items from the current page to the list
            all_items.extend(result.get('items', []))

            # Look for the "paging-next" link in the links
            url = next(
                (link['href'] for link in result.get(
                    '_meta',
                    {}).get(
                    'links',
                    []) if link.get('rel') == 'paging-next'),
                None)
        return all_items

    def get_project_by_name(self, project_name):
        '''Query project by name'''
        project = self._get_resource_by_name('name', 'projects', project_name)
        return project

    def get_project_version(self, project, version_name):
        '''Query project version by name'''
        version = self._get_resource_by_name(
            'versionName', 'versions', version_name, project)
        return version

    def get_bom_files(self, version):
        '''Produce a dictionary of files associated with components in a project version.'''
        component_files = defaultdict(list)
        local_file_prefix = 'file:///home/couchbase/workspace/blackduck-detect-scan/src/'
        version_url = version['_meta']['href']
        url = f"{version_url}/matched-files?limit=100"
        headers = {
            'Accept': 'application/vnd.blackducksoftware.bill-of-materials-6+json'
        }
        items = self._fetch_all_links(url, headers)

        for item in items:
            filepath = item.get('declaredComponentPath') or item.get(
                'uri', '')[len(local_file_prefix):]
            component_url = item['matches'][0]['component'].rsplit(
                '/origins', 1)[0]
            component_files[component_url].append(filepath)
        return component_files

    def group_vulnerability_entries(self, cve_list, component_files):
        ''' Group vulnerability entries by component version.  '''
        grouped_entries = []

        cve_list.sort(
            key=lambda x: (
                x['componentVersion'],
                x['updatedDate']),
            reverse=True)

        for k, g in groupby(cve_list, key=lambda x: x['componentVersion']):
            comp_entries = list(g)
            comp_dict = {
                k: comp_entries[0][k] for k in (
                    'componentVersion',
                    'componentName',
                    'componentVersionName',
                    'updatedDate')}
            comp_entries.sort(
                key=lambda x: constants.SEVERITY_LIST.index(
                    x['severity']))
            comp_dict['severity'] = comp_entries[0]['severity']
            comp_dict['cves'] = ','.join(
                sorted(set(x['cve_name'] for x in comp_entries)))
            comp_dict['links'] = '\n'.join(
                set(f"{x['severity']}:[ [{x['cve_name']}|{x['nist']}] ]" for x in comp_entries))
            comp_dict['files'] = component_files[comp_dict['componentVersion']]
            grouped_entries.append(comp_dict)

        return grouped_entries

    def group_journal_entries(self, cve_entries):
        ''' Aggregate journal entries by component version.  '''
        grouped_entries = []

        cve_entries.sort(
            key=lambda x: (
                x['componentName'],
                x['componentVersionName']))

        for k, g in groupby(cve_entries, key=lambda x: (
                x['componentName'], x['componentVersionName'])):
            comp_entries = list(g)
            comp_dict = {
                k: comp_entries[0][k] for k in (
                    'componentName',
                    'componentVersionName',
                    'updatedDate')}
            comp_entries.sort(
                key=lambda x: constants.SEVERITY_LIST.index(
                    x['severity']))
            comp_dict['severity'] = comp_entries[0]['severity']
            comp_dict['cves'] = ','.join(
                sorted(set(x['cve_name'] for x in comp_entries)))
            comp_dict['links'] = '\n'.join(set(
                f"{x['severity']}:[[{x['cve_name']}|{x['cve_link']}]]" for x in comp_entries))
            grouped_entries.append(comp_dict)

        return grouped_entries

    def get_bom_vulns(self, version):
        '''Retrieve vulnerabilities associated with a specific project version from Blackduck.'''
        vulns = []
        bom_url = f"{version['_meta']['href']}/vulnerable-bom-components?limit=100"
        headers = {
            'Accept': 'application/vnd.blackducksoftware.bill-of-materials-8+json'
        }
        items = self._fetch_all_links(bom_url, headers)
        vulns.extend(items)
        return vulns

    def prepare_vulnerability_entries(self, version):
        '''Prepare vulnerability entries for reporting.'''
        component_files = self.get_bom_files(version)
        entries = self.get_bom_vulns(version)

        cve_list = []
        for entry in entries:
            cve_name = entry['vulnerability']['vulnerabilityId']
            url = f"{self.base_url}/api/vulnerabilities/{cve_name}"
            cve_detail = self.hub_client.get_json(url)
            cve_link = next(
                (x['href'] for x in cve_detail['_meta']['links'] if x['rel'] == 'nist'), '')
            cve_list.append({
                'componentVersion': entry['componentVersion'],
                'componentName': entry['componentName'],
                'componentVersionName': entry['componentVersionName'],
                'cve_name': cve_name,
                'severity': cve_detail['severity'],
                'updatedDate': cve_detail['updatedDate'],
                'nist': cve_link
            })

        return self.group_vulnerability_entries(cve_list, component_files)

    def get_bom_status(self, version):
        '''Retrieve the BOM status for a project version.'''
        url = f"{version['_meta']['href']}/bom-status"
        headers = {
            'Accept': 'application/vnd.blackducksoftware.bill-of-materials-6+json'}
        result = self.hub_client.get_json(url, headers=headers)
        return result

    def get_version_journal(self, version, start_date):
        '''Retrieve journal entries from blackduck_hub updates for a project version.
           These are associated with blackduck_system user.
           We are only interested in these events:
           * Vulnerability Found:
                 New CVE found
           * Component Deleted:
                 Component is renamed.  It is usually followed by
                 "Component Added" and "Vulnerability Found".  We will close the
                 old issue and open a new one using the new name.
        '''
        date_string = start_date.isoformat()
        encoded_date_string = urllib.parse.quote(date_string)

        cve_entries, removed_entries = [], []
        url_base = version['_meta']['href'].replace(
            'api', 'api/journal')
        url = (
            f"{url_base}?sort=timestamp%20DESC"
            f"&filter=journalTriggerNames%3Ablackduck_system"
            f"&filter=journalDate%3A%3E%3D{encoded_date_string}"
            f"&filter=journalAction%3Avulnerability_detected"
            f"&filter=journalAction%3Acomponent_deleted"
            f"&limit=1000"
        )
        headers = {
            'Accept': 'application/vnd.blackducksoftware.journal-4+json'}
        activities = self.hub_client.get_json(url, headers=headers)

        if activities.get('totalCount') == 0:
            logging.info(
                'No vulnerability updates from Black Duck Hub since the last scan.')
            return [], []

        journal_entries = activities.get('items', [])
        for entry in journal_entries:
            if entry['action'] == 'Vulnerability Found':
                cve_name=entry['currentData']['vulnerabilityId']
                # Skip if CVE is in the exclusion list
                if cve_name in constants.EXCLUDED_CVE_LIST:
                    continue
                cve_link=f"https://nvd.nist.gov/vuln/detail/{entry['currentData']['vulnerabilityId']}"
                cve_entries.append({
                    'componentName': entry['currentData']['projectName'],
                    'componentVersionName': entry['currentData']['releaseVersion'],
                    'cve_name': cve_name,
                    'cve_link': cve_link,
                    'severity': entry['currentData']['riskPriority'].upper(),
                    'updatedDate': entry['timestamp']
                })
            elif entry['action'] == 'Component Deleted':
                removed_entries.append({
                    'componentName': entry['objectData']['name'],
                    'componentVersionName': entry['currentData']['version'],
                    'updatedDate': entry['timestamp']
                })

        grouped_update_entries = self.group_journal_entries(cve_entries)

        return grouped_update_entries, removed_entries
