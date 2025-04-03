#!/usr/bin/env python3

'''
This script creates a support ticket under Tools Project.
It is intended to inform the tools team about the new release.
i.e. https://couchbasecloud.atlassian.net/browse/TOOL-901
'''

import argparse
import logging
import sys
from jira_issue_manager import JiraIssueManager

logger = logging.getLogger('')
logger.setLevel(logging.INFO)
console_handler = logging.StreamHandler(stream=sys.stdout)
logger.addHandler(console_handler)

# Main
parser = argparse.ArgumentParser('Create Tools Ticket')
parser.add_argument('--product_name', required=True,
                    help='Product changed, i.e. Couchbase Server.')
parser.add_argument(
    '--version_build', required=True,
    help='Version and build number, i.e. 7.2.4: 7.2.4-7609, 7.2.3-MP2: 7.2.3-6710.')
parser.add_argument(
    '--release_date', required=True,
    help='Release date: i.e. Jan-12-2024, or January 12, 2024.')
args = parser.parse_args()

jira_session = JiraIssueManager()
issue_dict = {
    'project': {'key': 'TOOL'},
    'issuetype': {'name': 'Task'},
    'summary': 'Support Secret Sauce Update Request',
    'description': (
        f'Product Changed: {args.product_name}\n'
        f'Version/Build Number: {args.version_build}\n'
        f'Release Date: {args.release_date}\n'
    )
}
result = jira_session.client.create_issue(issue_dict)
logger.info(f'{result}')
