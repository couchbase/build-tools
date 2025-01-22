#!/usr/bin/env python3

import sys
import json
import logging
from collections import defaultdict
from pathlib import Path
from itertools import groupby
import urllib
from blackduck.HubRestApi import HubInstance
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

        self.hub = HubInstance(
            bd_creds['url'],
            bd_creds['username'],
            bd_creds['password'],
            insecure=True
        )

    def get_bom_files(self, version_url):
        '''Produce a dictionary of files associated with components in a project version.'''
        component_files = defaultdict(list)
        url = f"{version_url}/matched-files?limit=3000"
        local_file_prefix = 'file:///home/couchbase/workspace/blackduck-detect-scan/src/'

        response = self.hub.execute_get(url)
        if response.status_code == 200:
            for item in response.json().get('items', []):
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
        limit, offset, vulns = 1000, 0, []
        bom_url = f"{version['_meta']['href']}/vulnerable-bom-components"
        bom_headers = {
            'Accept': 'application/vnd.blackducksoftware.bill-of-materials-6+json'}

        while True:
            response = self.hub.execute_get(
                f'{bom_url}?limit={limit}&offset={offset}',
                custom_headers=bom_headers)
            if response.status_code != 200:
                logging.error(
                    f"Failed to fetch vulnerabilities: {response.text}")
                break
            vulns.extend(response.json().get('items', []))
            offset += limit
            if len(vulns) >= response.json().get('totalCount', 0):
                break

        return vulns

    def prepare_vulnerability_entries(self, version):
        '''Prepare vulnerability entries for reporting.'''
        url = version['_meta']['href']
        component_files = self.get_bom_files(url)
        raw_entries = self.get_bom_vulns(version)

        cve_list = []
        for entry in raw_entries:
            cve_name = entry['vulnerabilityWithRemediation']['vulnerabilityName']
            cve_detail = self.hub.get_vulnerabilities(cve_name)
            cve_link = next(
                (x['href'] for x in cve_detail['_meta']['links'] if x['rel'] == 'nist'), '')

            cve_list.append({
                'componentVersion': entry['componentVersion'],
                'componentName': entry['componentName'],
                'componentVersionName': entry['componentVersionName'],
                'cve_name': cve_name,
                'severity': entry['vulnerabilityWithRemediation']['severity'],
                'updatedDate': entry['vulnerabilityWithRemediation']['vulnerabilityUpdatedDate'],
                'nist': cve_link
            })

        return self.group_vulnerability_entries(cve_list, component_files)

    def get_bom_status(self, version):
        '''Retrieve the BOM status for a project version.'''
        url = f"{version['_meta']['href']}/bom-status"
        headers = {
            'Accept': 'application/vnd.blackducksoftware.bill-of-materials-6+json'}
        response = self.hub.execute_get(url, custom_headers=headers)

        if response.status_code == 200:
            return response.json()
        else:
            logging.error('Unable to determine scan status.')
            sys.exit(1)

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

        cve_entries = []
        removed_entries = []
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
        journal_headers = {
            'Accept': 'application/vnd.blackducksoftware.journal-4+json'}
        activities = self.hub.execute_get(url, custom_headers=journal_headers)

        if activities.json().get('totalCount') == 0:
            logging.info(
                'No vulnerability updates from Black Duck Hub since the last scan.')
            return [], []

        journal_entries = activities.json().get('items', [])
        for entry in journal_entries:
            if entry['action'] == 'Vulnerability Found':
                cve_entries.append({
                    'componentName': entry['currentData']['projectName'],
                    'componentVersionName': entry['currentData']['releaseVersion'],
                    'cve_name': entry['currentData']['vulnerabilityId'],
                    'cve_link': entry['objectData']['link'],
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
