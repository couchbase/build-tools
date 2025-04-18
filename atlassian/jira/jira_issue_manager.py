import json
import logging
import sys
from pathlib import Path
import requests
from requests.auth import HTTPBasicAuth
from jira import JIRA

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)


class JiraIssueManager:
    def __init__(self):
        '''Initialize the Jira client.'''
        cloud_creds_file = str(Path.home()) + '/.ssh/cloud-jira-creds.json'
        if Path(cloud_creds_file).exists():
            self.cloud_jira_creds = json.loads(open(cloud_creds_file).read())
        else:
            logging.error('Unable to locate cloud-jira-creds.json')
            sys.exit(1)

        self.client = JIRA(self.cloud_jira_creds['url'], basic_auth=(
            f"{self.cloud_jira_creds['username']}",
            f"{self.cloud_jira_creds['apitoken']}"))

        self.api_url = f"{self.cloud_jira_creds['url']}/rest/api/3"

    def _make_api_request(self, method, endpoint, data=None):
        '''Helper function to make API requests.'''
        url = f"{self.api_url}/{endpoint}"
        auth = HTTPBasicAuth(
            self.cloud_jira_creds['username'],
            self.cloud_jira_creds['apitoken'])
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json"
        }

        response = requests.request(
            method,
            url,
            headers=headers,
            auth=auth,
            data=json.dumps(data) if data else None
        )

        return response

    def search_jira_issues(self, search_str, batch_size=100):
        """Helper function to handle paginated Jira searches"""
        issues = []
        start_at = 0
        while True:
            batch = self.client.search_issues(
                search_str,
                startAt=start_at,
                maxResults=batch_size,
                fields='key,versions,issuelinks',
                json_result=True
            )
            if not batch:
                break

            issues.extend(batch['issues'])
            if start_at + batch_size >= batch['total']:
                break
            start_at += batch_size
        return issues

    def update_issue(self, issue_key, issue_fields, notify=True):
        '''Update Jira issue fields.'''
        logging.info(f'Updating issue {issue_key} with fields {issue_fields}')
        self.client.issue(issue_key).update(fields=issue_fields, notify=notify)

    def get_projects_in_category(self, category_name):
        '''Get all projects in a specific category.'''
        all_projects = []
        start_at = 0
        max_results = 50
        while True:
            # Make paginated API request
            response = self._make_api_request(
                "GET", f"project/search?startAt={start_at}&maxResults={max_results}")
            projects_page = response.json()

            if not projects_page.get('values'):
                break

            all_projects.extend(projects_page['values'])

            # Check if we've retrieved all projects
            if start_at + max_results >= projects_page.get('total', 0):
                break

            start_at += max_results

        # Filter projects by category
        category_projects = []
        for project in all_projects:
            if (project.get('projectCategory') and
                    project['projectCategory'].get('name') == category_name):
                category_projects.append(project['key'])

        return category_projects

    def get_filter_by_name(self, jira_filter_name):
        '''Get Jira filter by name.'''
        result = self._make_api_request("GET", "filter/search")
        jira_filters = result.json().get('values')
        for jira_filter in jira_filters:
            if jira_filter['name'] == jira_filter_name:
                return jira_filter
        return None

    def share_filter(self, jira_filter):
        '''Make Jira filter internally accessible.'''
        share_permissions = {
            "type": "group",
            "groupname": "jira-users"
        }
        return self._make_api_request(
            "POST", f"filter/{jira_filter['id']}/permission", share_permissions)

    def create_filter(self, jira_filter_name, jql):
        '''Create a Jira filter.'''
        data = {
            "jql": jql,
            "description": "generated by script",
            "name": jira_filter_name
        }
        jira_filter = self._make_api_request("POST", "filter", data).json()
        if jira_filter:
            self.share_filter(jira_filter)
            return jira_filter
        return None

    def update_filter(self, jira_filter, jql):
        '''Update a Jira filter.'''
        self.client.update_filter(jira_filter.id, jql=jql)
