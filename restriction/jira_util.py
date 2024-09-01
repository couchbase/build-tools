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
  Returns a list of ticket IDs mentioned in a string.
  """

  # This regex means "Between 2 and 5 uppercase letters, followed by a
  # dash, followed by 1 to 6 numbers, and NOT followed by a dash or a
  # number". The last bit is to prevent it from matching CVEs, eg.
  # CVE-2023-12345. I could have just skipped any matches that started
  # with "CVE", but then if we ever had a "CVE" Jira project it wouldn't
  # match those. Also, putting \b at the front and back of the regex
  # makes it match only at word boundaries, so something like
  # NOTATICKET-1234 won't be matched as "ICKET-1234".
  return re.findall(r"\b[A-Z]{2,5}-[0-9]{1,6}(?![-0-9])\b", message)
