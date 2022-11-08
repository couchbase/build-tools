#!/usr/bin/env python3

import sys
import json
import timestring
from blackduck.HubRestApi import HubInstance
from collections import defaultdict
from pathlib import Path


class Blackduck:
    def __init__(self):
        creds_file = str(Path.home()) + '/.ssh/blackduck-creds.json'
        if Path(creds_file).exists():
            bd_creds = json.loads(open(creds_file).read())
        else:
            sys.exit('Unable to locate blackduck-creds.json')

        self.hub = HubInstance(
            bd_creds['url'],
            bd_creds['username'],
            bd_creds['password'],
            insecure=True)

    def get_notifications(self, filter_url):
        current_user = self.hub.get_current_user()
        notifications_url = self.hub.get_link(current_user, "notifications")

        url = f"{notifications_url}?{filter_url}"
        response = self.hub.execute_get(url)

        if response.status_code == 200:
            limit = response.json().get('totalCount', [])
            response = self.hub.execute_get(
                f"{notifications_url}?limit={limit}")
            if response.status_code == 200:
                notifications = response.json().get('items', [])
                return notifications
            else:
                sys.exit('Failed to retrieve notifications')
        else:
            sys.exit('Failed to retrieve notifications.')

    def get_vulnerability_notifications(
            self, project_name, version_name, newer_than, older_than):
        notifications = self.get_notifications(
            "filter=notificationType%3Avulnerability")

        # further reduce noises from project creations, unknown components,
        # etc.
        vulnerability_notifications = [
            v for v in notifications if v['type'] == "VULNERABILITY"]

        if newer_than:
            vulnerability_notifications = list(
                filter(lambda n: timestring.Date(n['createdAt']) > newer_than, vulnerability_notifications))
        if older_than:
            vulnerability_notifications = list(
                filter(lambda n: timestring.Date(n['createdAt']) < older_than, vulnerability_notifications))
        if project_name:
            vulnerability_notifications = list(
                filter(lambda n: project_name in [apv['projectName'] for apv in n['content']['affectedProjectVersions']],
                       vulnerability_notifications))
            if version_name:
                vulnerability_notifications = list(
                    filter(lambda n: version_name in [apv['projectVersionName'] for apv in n['content']['affectedProjectVersions']],
                           vulnerability_notifications))
        return vulnerability_notifications

    # Create cve dictionaries

    def create_cve_dicts(self, cves):
        dicts = {}
        for cve in cves:
            dicts[cve] = self.hub.get_vulnerabilities(cve)
        return dicts

    # Create a mapping between component version and files
    # Couchbase-server has less than 2000 matched-files, 3000 should be more than sufficient
    # According to blackduck, /api/projects/<projectid>/versions/<project_version_id>/components/<component_id>/versions/<component_version_id>/matched-files
    # does not provide direct dependencies.  We have to use /api/projects/<projectid>/versions/<project_version_id>/matched-files to get a full list of
    # components and corresponding files.

    def get_project_version_files(self, project_version_url):
        project_version_files = defaultdict(list)
        url = project_version_url + '/matched-files?limit=3000'
        response = self.hub.execute_get(url)
        local_file_prefix = 'file:///home/couchbase/workspace/blackduck-detect-scan/src/'
        if response.status_code == 200:
            for item in response.json().get('items'):
                # declaredComponentPath: FILE_DEPENDENCY_DIRECT and FILE_DEPENDENCY_TRANSITIVE
                # uri: FILE_EXACT, MANUAL_BOM_FILE, FILE_SOME_FILES_MODIFIED, FILE_FILES_ADDED_DELETED_AND_MODIFIED
                #      These tends to have leading path of WORKSPACE.
                if 'declaredComponentPath' in item.keys():
                    filepath = item['declaredComponentPath']
                if 'uri' in item.keys():
                    filepath = item['uri'][len(local_file_prefix):]
                component_url = item['matches'][0]['component'].rsplit(
                    '/origins', 1)[0]
                project_version_files[component_url].append(filepath)
        else:
            sys.exit('unable to find matching files...')

        return project_version_files

    # get vulnerabilities by project and version, filter out ignored,
    # mitigated, patched, remediation complete, and duplicate
    def get_vulnerability_bom(self, project_version_url):
        url = project_version_url + \
            '/vulnerability-bom?filter=remediationType%3Anew&filter=remediationType%3Aneeds_review&filter=remediationType%3Aremediation_required'
        response = self.hub.execute_get(url)
        if response.status_code == 200:
            return json.loads(response.text)['items']
        else:
            sys.exit('Failed to retrieve vulnerabilities from {}'.format(url))

    # return project dict
    def get_project_by_name(self, project_name):
        return self.hub.get_project_by_name(project_name)

    # return a list version dicts
    def get_project_version_url(self, project, version_name):
        if version_name:
            version = self.hub.get_version_by_name(project, version_name)
            return [version]
        else:
            versions = self.hub.get_project_versions(project)
            return versions['items']

    # get url
    def get_url(self, url):
        response = self.hub.execute_get(url)
        if response.status_code == 200:
            return response.json().get('items', [])
        else:
            sys.exit('Failed to get result from {}'.format(url))
