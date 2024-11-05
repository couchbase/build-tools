import json
from jira import JIRA
import os
import re

def connect_jira():
  """
  Uses cloud-jira-creds.json in ~/.ssh to authenticate to jira cloud.
  cloud-jira-creds.json contains:
      username
      apitoken
      url
      cloud=true
  """
  cloud_jira_creds_file = f'{os.environ["HOME"]}/.ssh/cloud-jira-creds.json'
  cloud_jira_creds = json.loads(open(cloud_jira_creds_file).read())
  jira = JIRA(cloud_jira_creds['url'], basic_auth=(
              f"{cloud_jira_creds['username']}",
              f"{cloud_jira_creds['apitoken']}"))
  return jira

def get_tickets(message):
  """
  Returns a list of ticket IDs mentioned in a string. Filter out any "foreign"
  projects like ASTERIXDB.
  """

  foreign = ['ASTERIXDB', 'BP']
  return (
    x.group(0) for x in re.finditer("([A-Z]{2,9})-[0-9]{1,6}", message)
      if x.group(1) not in foreign
  )
