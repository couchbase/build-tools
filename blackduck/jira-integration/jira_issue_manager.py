import json
import logging
import sys
from pathlib import Path
from jira import JIRA

import constants

class JiraIssueManager:
    def __init__(self):
        '''Initialize the Jira client.'''
        cloud_creds_file = str(Path.home()) + '/.ssh/cloud-jira-creds.json'
        if Path(cloud_creds_file).exists():
            cloud_jira_creds = json.loads(open(cloud_creds_file).read())
        else:
            sys.exit('Unable to locate cloud-jira-creds.json')

        self.client = JIRA(cloud_jira_creds['url'], basic_auth=(
            f"{cloud_jira_creds['username']}",
            f"{cloud_jira_creds['apitoken']}"))

    def format_issue_fields(self, field_info, project, version):
        '''Generate issue fields for creating or updating a Jira issue.'''
        issue_summary = (
            f"{project}:{version},"
            f"{field_info['componentName']}:{field_info['componentVersionName']}"
         )

        # Issue description
        bd_detail = (
            f"*Project*: {project}\n"
            f"*Project Version*: {version}\n"
            f"---------------------------------------\n"
            f"*Component*: *{field_info['componentName']}*\n"
            f"*Component Version*: {field_info['componentVersionName']}\n"
            f"---------------------------------------\n"
            f"*Vulnerabilities*:\n{{anchor}}\n"
            f"{field_info.get('links','')}\n{{anchor}}\n"
            f"\n---------------------------------------\n"
            f"*Files*:\n{field_info.get('files','')}"
        )

        issue_fields = {
            'project': constants.JIRA_PROJECT_KEY,
            'summary': issue_summary,
            'description': '',
            'issuetype': {'name': constants.JIRA_ISSUE_TYPE},
            # 'components': [{'name': f"{issue_dict['cb_component']}"}],
            constants.BD_DETAIL_FIELD: bd_detail,
            constants.BD_COMPONENT_FIELD: field_info['componentName'],
            constants.BD_COMPONENT_VERSION_FIELD: field_info['componentVersionName'],
            constants.BD_PROJECT_FIELD: project,
            constants.BD_PROJ_VERSION_FIELD: version,
            constants.BD_SEVERITY_FIELD: field_info['severity'],
            constants.BD_CVES_FIELD: field_info['cves'],
            constants.BD_LAST_UPDATE_FIELD: field_info['updatedDate']
        }

        return issue_fields

    def search_related_issues(
            self, bd_comp, bd_comp_ver, bd_proj):
        '''Find related issues.'''
        related_issues = []
        # Double quotes in JQL are used to deal with spaces and special characters
        # i.e.
        #   * When searching BD_COMPONENT~"AWS JDK", it returns any ticket containing either word
        #     "\\"AWS JDK\\"" returns tickets contains the phrase
        #   * BD_PROJECT~"couchbase-server" will not return anything associated with couchbase-server.
        #     We have to use "\\"couchbase-server\\"" in the JQL
        search_str = (
            f'project={constants.JIRA_PROJECT_KEY} and '
            f'BD_COMPONENT~"\\"{bd_comp}\\"" and BD_COMP_VERSION~"'
            f'{bd_comp_ver}" and BD_PROJECT~"\\"{bd_proj}\\""')
        issues = self.client.search_issues(search_str)
        for issue in issues:
            if getattr(issue.fields, constants.BD_COMPONENT_FIELD) == bd_comp:
                related_issues.append(issue)
        return related_issues

    def search_issue(self, bd_comp,
                     bd_comp_ver, bd_proj, bd_proj_ver):
        '''Search issue by blackduck component and version in VULN project.'''
        # Double quotes in JQL are used to deal with spaces and special characters
        search_str = (
            f'project={constants.JIRA_PROJECT_KEY} and '
            f'BD_COMPONENT~"\\"{bd_comp}\\"" and BD_COMP_VERSION~"'
            f'{bd_comp_ver}" and BD_PROJECT~"\\"{bd_proj}\\"" and BD_PROJ_VERSION~"{bd_proj_ver}"')
        issues = self.client.search_issues(search_str)
        for issue in issues:
            if (
                getattr(
                    issue.fields,
                    constants.BD_COMPONENT_FIELD) == bd_comp) and (
                getattr(
                    issue.fields,
                    constants.BD_COMPONENT_VERSION_FIELD) == bd_comp_ver) and (
                    getattr(
                        issue.fields,
                        constants.BD_PROJ_VERSION_FIELD) == bd_proj_ver):
                return issue

        return None

    def find_project_version_issues(
            self,
            project_name,
            project_version):
        '''Find all issues for a specific project and version.'''
        offset = 0
        issues = []
        # Double quotes in JQL are used to deal with spaces and special characters
        search_str = (
            f'project={constants.JIRA_PROJECT_KEY} '
            f'and BD_PROJECT~"\\"{project_name}\\"" '
            f'and BD_PROJ_VERSION~"{project_version}"'
        )
        while True:
            response = self.client.search_issues(
                search_str, json_result=True, startAt=offset)
            if offset == 0:
                total = response.get('total', [])
            issues.extend(response.get('issues', []))
            offset += 50
            if offset >= total:
                break
        return issues

    def new_issue(self, ticket_info, project, version):
        '''Create a new issue in the Jira project.'''
        issue_fields = self.format_issue_fields(ticket_info, project, version)
        return self.client.create_issue(fields=issue_fields)

    def update_issue(self, issue, new_fields_info, project, version):
        '''Update an existing Jira issue with new details.'''
        updated_issue_fields = self.format_issue_fields(new_fields_info, project, version)
        issue.update(fields=updated_issue_fields)

    def transition_issue(
            self,
            issue,
            transition,
            issue_fields):
        '''Transition a Jira issue to a new status.'''
        self.client.transition_issue(
            issue,
            transition,
            fields=issue_fields)

    def create_issue_link(self, src_key, dest_key):
        '''Create a link between two Jira issues.'''
        self.client.create_issue_link('relates to', src_key, dest_key)
