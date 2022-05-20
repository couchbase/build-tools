import json
import logging
import sys
from jira import JIRA
from pathlib import Path

import config

class JiraRestApi:
    def __init__ (self):
        creds_file = str(Path.home()) + '/.ssh/jira-creds.json'
        if Path(creds_file).exists():
            jira_creds =json.loads(open(creds_file).read())
        else:
            sys.exit('Unable to locate jira-creds.json')

        self.jira = JIRA( server=jira_creds['url'],
            token_auth=jira_creds['apitoken'],  # Self-Hosted Jira (e.g. Server): the PAT token
        )

    def search_issues (self, jira_proj_key, bd_comp, bd_comp_ver, bd_proj, bd_proj_ver=None):
        if bd_proj_ver:
            search_str = (f'project={jira_proj_key} and BD_COMPONENT~"{bd_comp}" and BD_COMP_VERSION~"'
                          f'{bd_comp_ver}" and BD_PROJECT~"{bd_proj}" and BD_PROJ_VERSION~"{bd_proj_ver}"')
        else:
            search_str = (f'project={jira_proj_key} and BD_COMPONENT~"{bd_comp}" and BD_COMP_VERSION~"'
                          f'{bd_comp_ver}" and BD_PROJECT~"{bd_proj}"')
        issues=self.jira.search_issues(search_str)
        return issues

    def new_issue (self, project, issue_dict):
        cves = ','.join(issue_dict['cves_list'])
        issue_fields = {
            'project': project,
            'summary': f'{issue_dict["summary"]}',
            'description': '',
            'issuetype': {'name': config.JIRA['issue_type']},
            'components': [{ 'name': f'{issue_dict["cb_component"]}'}],
            config.JIRA['BD_DETAIL']: f'{issue_dict["detail"]}',
            config.JIRA['BD_COMPONENT']: f'{issue_dict["component_name"]}',
            config.JIRA['BD_COMP_VERSION']: f'{issue_dict["version"]}',
            config.JIRA['BD_PROJECT']: f'{issue_dict["project_name"]}',
            config.JIRA['BD_PROJ_VERSION']: f'{issue_dict["project_version"]}',
            config.JIRA['BD_SEVERITY']: f'{issue_dict["severity"]}',
            config.JIRA['BD_CVES']: f'{cves}',
            config.JIRA['BD_LAST_UPDATE']: f'{issue_dict["date"]}'
        }
        return self.jira.create_issue(fields=issue_fields)

    def update_issue (self, issue, issue_dict):
        issue_fields = {
            config.JIRA['BD_DETAIL']: f'{issue_dict["detail"]}',
            config.JIRA['BD_LAST_UPDATE']: f'{issue_dict["date"]}'
        }
        if 'severity' in issue_dict.keys():
            issue_fields[config.JIRA['BD_SEVERITY']] = f'{issue_dict["severity"]}'
        if 'cves_list' in issue_dict.keys():
            cves = ','.join(issue_dict['cves_list'])
            issue_fields[config.JIRA['BD_CVES']] = f'{cves}'

        return issue.update(fields=issue_fields)

    def transition_issue (self, issue, transition, bd_update_date):
        self.jira.transition_issue(issue, transition)
        issue_fields = {
            config.JIRA['BD_LAST_UPDATE']: f'{bd_update_date}'
        }
        issue.update(fields=issue_fields)

    def create_issue_link (self, src_key, dest_key):
        self.jira.create_issue_link('relates to', src_key, dest_key)
