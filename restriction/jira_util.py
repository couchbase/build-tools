import json
from jira import JIRA
import os
import re

def connect_jira():
  """
  Uses private files in ~/.ssh to create a connection to Couchbase Jira. Uses
  Python Jira library. See
  https://developer.atlassian.com/jiradev/jira-apis/jira-rest-apis/jira-rest-api-tutorials/jira-rest-api-example-oauth-authentication

  Expected files:
    build_jira.pem - Private key registered with Jira Application
    build_jira.json - JSON block with "access_token", "access_token_secret",
       and "consumer_key" fields as generated per above URL
  """
  with open("{}/.ssh/issues-jira-creds.json".format(os.environ["HOME"]), "r") as oauth_file:
    jira_creds = json.load(oauth_file)
  jira = JIRA(server=jira_creds['url'], token_auth=jira_creds['apitoken'])
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
