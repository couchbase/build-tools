import json
from jira import JIRA
from jira.exceptions import JIRAError
import os
import re

def connect_jira():
  """
  Connects to JIRA using credentials from either:
  1. Environment variables JIRA_URL, JIRA_USERNAME, and JIRA_API_TOKEN (for GitHub Actions)
  2. cloud-jira-creds.json in ~/.ssh (for Gerrit)

  For file-based auth, cloud-jira-creds.json contains:
      username
      apitoken
      url
      cloud=true
  """
  # Check if environment variables are set (GitHub Actions)
  jira_url = os.getenv("JIRA_URL")
  jira_user = os.getenv("JIRA_USERNAME")
  jira_token = os.getenv("JIRA_API_TOKEN")

  if jira_url and jira_user and jira_token:
    # Use GitHub Actions credentials
    try:
      # First validate that credentials have reasonable format
      if not jira_url.startswith(('http://', 'https://')):
        raise Exception(f"JIRA connection failed: Invalid JIRA URL format '{jira_url}'. URL must start with http:// or https://")

      if len(jira_token) < 5:  # Very basic sanity check
        raise Exception("JIRA authentication failed: API token is too short. Please check your JIRA_API_TOKEN secret.")

      jira = JIRA(jira_url, basic_auth=(jira_user, jira_token))
      # Test the connection with a simple query to verify authentication
      jira.myself()
      return jira
    except JIRAError as e:
      if e.status_code == 401:
        raise Exception("JIRA authentication failed: Invalid username or API token. Please check your JIRA credentials and ensure the API token is not expired.")
      elif e.status_code == 403:
        raise Exception("JIRA authentication failed: Access forbidden. Please check your JIRA permissions.")
      elif e.status_code == 404:
        raise Exception(f"JIRA connection failed: Invalid JIRA URL '{jira_url}'. Please verify the URL is correct.")
      else:
        raise Exception(f"JIRA connection failed: {e.text if hasattr(e, 'text') else str(e)}")
    except Exception as e:
      if "401" in str(e) or "Unauthorized" in str(e):
        raise Exception("JIRA authentication failed: Invalid username or API token. Please check your JIRA credentials and ensure the API token is not expired.")
      elif "403" in str(e) or "Forbidden" in str(e):
        raise Exception("JIRA authentication failed: Access forbidden. Please check your JIRA permissions.")
      elif "timeout" in str(e).lower() or "connection" in str(e).lower():
        raise Exception(f"JIRA connection failed: Unable to connect to '{jira_url}'. Please check the URL and network connectivity.")
      else:
        raise Exception(f"JIRA connection failed: {str(e)}")
  else:
    # Fall back to file-based credentials (Gerrit)
    try:
      cloud_jira_creds_file = f'{os.environ["HOME"]}/.ssh/cloud-jira-creds.json'
      cloud_jira_creds = json.loads(open(cloud_jira_creds_file).read())
      jira = JIRA(cloud_jira_creds['url'], basic_auth=(
                  f"{cloud_jira_creds['username']}",
                  f"{cloud_jira_creds['apitoken']}"))
      # Test the connection
      jira.myself()
      return jira
    except FileNotFoundError:
      raise Exception(f"JIRA credentials file not found at {cloud_jira_creds_file}")
    except json.JSONDecodeError:
      raise Exception(f"Invalid JSON in JIRA credentials file: {cloud_jira_creds_file}")
    except JIRAError as e:
      if e.status_code == 401:
        raise Exception("JIRA authentication failed: Invalid username or API token in credentials file. Please check the token is not expired.")
      elif e.status_code == 403:
        raise Exception("JIRA authentication failed: Access forbidden. Please check your JIRA permissions.")
      else:
        raise Exception(f"JIRA connection failed: {e.text if hasattr(e, 'text') else str(e)}")
    except Exception as e:
      if "401" in str(e) or "Unauthorized" in str(e):
        raise Exception("JIRA authentication failed: Invalid username or API token in credentials file. Please check the token is not expired.")
      else:
        raise Exception(f"JIRA connection failed: {str(e)}")

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
