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

UPDATED_DATE_LIMIT = '-78w' # 1.5 years
STANDALONE_JIRA_PROJECTS = {
    'MB': {
        'ISSUE_TYPES': ('Bug', 'Task', 'Improvement'),
        # JQL pattern to ignore release tickets
        'EXTRA_JQL_PATTERN': '(labels is EMPTY OR labels not in ("tracking"))'
    },
    'AV': {
        'ISSUE_TYPES': ('Bug', '\"Bug Sub-Task\"', 'Task', 'Improvement',
                        'Epic', 'Initiative', '\"Sub-task\"'),
        'EXTRA_JQL_PATTERN': ''
    }
}
JIRA_CATEGORIES = {
    'Couchbase Client Libraries': {
        'ISSUE_TYPES': ('Bug', 'Task', 'Improvement', 'Epic', '\"New Feature\"'),
        'EXTRA_JQL_PATTERN': ''
    },
    'Couchbase Mobile': {
        'ISSUE_TYPES': ('Bug', 'Task', 'Improvement', 'Epic', '\"New Feature\"'),
        # JQL pattern to ignore release tickets
        'EXTRA_JQL_PATTERN': '(labels is EMPTY OR labels not in ("release"))'
    }
}

ISSUE_IMPACT_FIELD_ID = '12659'


def has_cbse_link(issue):
    '''Check if issue has a linked Bug or Task in CBSE project'''

    for link in issue['fields']['issuelinks']:
        linked_issue = link.get('outwardIssue') or link.get('inwardIssue')
        if (linked_issue and
            linked_issue['key'].startswith('CBSE-') and
                linked_issue['fields']['issuetype']['name'] in ['Bug', 'Task']):
            return True
    return False


def find_tickets_with_linked_cbse(jira_session, project_key, category=None):
    '''
        Find tickets of given version:
            - types of Bug, Task, and Improvement
            - have issue associated with CBSE project
        Return a list of issue keys
    '''
    if category:
        config = JIRA_CATEGORIES[category]
    else:
        config = STANDALONE_JIRA_PROJECTS[project_key]
    issue_types = config['ISSUE_TYPES']
    search_str = (
        f'project={project_key} AND '
        f'cf[{ISSUE_IMPACT_FIELD_ID}] is EMPTY AND '
        f'issueLinkType is not EMPTY AND '
        f'issuetype in ({", ".join(issue_types)}) AND '
        f'updated >= "{UPDATED_DATE_LIMIT}"'
    )
    if extra_jql := config.get("EXTRA_JQL_PATTERN"):
        search_str += f' AND {extra_jql}'

    issues = jira_session.search_jira_issues(search_str)
    return [issue['key'] for issue in issues if has_cbse_link(issue)]


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
    for project in STANDALONE_JIRA_PROJECTS:
        logger.info(
            f'Checking {project}...')
        issues_to_set = find_tickets_with_linked_cbse(
            session,
            project,
        )
        logger.info(
            f'set issue_impact field to external for {project}: {issues_to_set}')
        for issue in issues_to_set:
            session.update_issue(issue, set_issue_impact_field_external, notify=False)
    for category in JIRA_CATEGORIES:
        projects = session.get_projects_in_category(category)
        for project in projects:
            logger.info(
                f'Checking {project}...')
            issues_to_set = find_tickets_with_linked_cbse(
                session,
                project,
                category
            )
            logger.info(
                f'set issue_impact field to external for {project}: {issues_to_set}')
            for issue in issues_to_set:
                session.update_issue(issue, set_issue_impact_field_external, notify=False)
