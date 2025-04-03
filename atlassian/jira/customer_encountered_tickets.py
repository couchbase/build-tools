'''
This script updates Jira tickets' Issue_Impact customfield based on association with CBSE project.

It performs two main operations:
1. Sets Issue_Impact to "external" for
    - Bug, Task, or Improvement
    - have a linked to CBSE bug or task
2. Clears Issue_Impact field for
    - Bug, Task, or Improvement
    - do not have linked tiket to CBSE
'''

import logging
from jira_issue_manager import JiraIssueManager

logger = logging.getLogger(__name__)

JIRA_PROJECTS = {
    'MB': {
        'VERSIONS': ['7.2', '7.6'],
        # JQL pattern to ignore release tickets
        'EXTRA_JQL_PATTERN': '(labels is EMPTY OR labels not in ("tracking"))'
    }
}
ISSUE_IMPACT_FIELD_ID = '12659'


def has_cbse_link(issue):
    '''Check if issue has a linked Bug or Task in CBSE project'''
    if 'issuelinks' not in issue['fields'] or not issue['fields']['issuelinks']:
        return False

    for link in issue['fields']['issuelinks']:
        linked_issue = link.get('outwardIssue') or link.get('inwardIssue')
        if (linked_issue and
            linked_issue['key'].startswith('CBSE-') and
                linked_issue['fields']['issuetype']['name'] in ['Bug', 'Task']):
            return True
    return False


def find_tickets_with_linked_cbse(jira_session, project_key, affected_version):
    '''
        Find tickets of given version:
            - types of Bug, Task, and Improvement
            - have issue associated with CBSE project
        Return a list of issue keys
    '''
    search_str = (
        f'project={project_key} AND '
        f'issuetype in (Bug, Task, Improvement) AND '
        f'(affectedVersion ~ "{affected_version}" OR affectedVersion ~ "{affected_version}.*") AND '
        f'cf[{ISSUE_IMPACT_FIELD_ID}] is EMPTY'
    )
    if extra_jql := JIRA_PROJECTS[project_key].get("EXTRA_JQL_PATTERN"):
        search_str += f' AND {extra_jql}'

    issues = jira_session.search_jira_issues(search_str)
    return [issue['key'] for issue in issues if has_cbse_link(issue)]


def external_impact_tickets_without_cbse(jira_session, project_key):
    '''
        Find tickets of given project that:
            - types of Bug, Task, and Improvement
            - do not have a linked issue associated with CBSE project
            - have issue impact wrongly set to external
        Return a list of issue keys
    '''
    search_str = (
        f'project={project_key} AND '
        f'issuetype in (Bug, Task, Improvement) AND '
        f'cf[{ISSUE_IMPACT_FIELD_ID}] in ("external")'
    )
    if extra_jql := JIRA_PROJECTS[project_key].get("EXTRA_JQL_PATTERN"):
        search_str += f' AND {extra_jql}'

    issues = jira_session.search_jira_issues(search_str)
    return [issue['key'] for issue in issues if not has_cbse_link(issue)]


if __name__ == '__main__':
    issue_impact_field = f'customfield_{ISSUE_IMPACT_FIELD_ID}'
    set_issue_impact_field_external = {
        issue_impact_field: {
            "value": "external"
        }
    }
    unset_issue_impact_field = {
        issue_impact_field: None
    }
    session = JiraIssueManager()
    for project in JIRA_PROJECTS:
        for version in JIRA_PROJECTS[project]['VERSIONS']:
            issues_to_set = find_tickets_with_linked_cbse(
                session,
                project,
                version
            )
            logger.info(
                f'set issue_impact field to external for {project} {version}: {issues_to_set}')
            for issue in issues_to_set:
                session.update_issue(issue, set_issue_impact_field_external)

        issues_to_unset = external_impact_tickets_without_cbse(
            session,
            project
        )
        logger.info(
            f'unset issue_impact field for {project}: {issues_to_unset}')
        for issue_key in issues_to_unset:
            session.update_issue(issue_key, unset_issue_impact_field)
