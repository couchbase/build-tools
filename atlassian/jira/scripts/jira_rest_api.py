#!/usr/bin/env python3
'''
functions to Atlassian Jira Module.
'''

import json
import sys
from pathlib import Path
from atlassian import Jira


class JiraRestApi:
    def __init__(self, cred_file_path=str(Path.home()) + '/.ssh/cloud-jira-creds.json'):
        if Path(cred_file_path).exists():
            #jira_creds = json.loads(open(cred_file).read())
            with open(cred_file_path, 'r', encoding='utf-8') as cred_file:
                jira_creds = json.loads(cred_file.read())
        else:
            sys.exit(f'Unable to locate {cred_file_path}')

        self.jira = Jira(url=jira_creds['url'],
                         username=f"{jira_creds['username']}",
                         password=f"{jira_creds['apitoken']}",
                         cloud=jira_creds['cloud'])
