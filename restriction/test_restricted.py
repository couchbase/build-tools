#!/usr/bin/env python

import argparse
import subprocess
import os
import base64

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("project", type=str, help="Project to check")
    parser.add_argument("message", type=str, help="Commit message to check",
      nargs="?", default="")
    parser.add_argument("-b", "--branch", type=str, default="master",
      help="Branch to check")
    parser.add_argument("-c", "--change", type=str, default="55555",
      help="Gerrit change ID (affects output only; required for checking manifest project)")
    parser.add_argument("--patchset", type=str, default="1",
      help="Gerrit patchset ID (affects output only; required for checking manifest project)")
    parser.add_argument("-p", "--manifest-project", type=str,
      default="https://github.com/couchbase/manifest",
      help="Alternate Git project for manifest")
    parser.add_argument("--github", action="store_true",
      help="Simulate GitHub Actions environment instead of Gerrit")
    parser.add_argument("--pr-number", type=str, default="123",
      help="GitHub PR number when using --github")
    parser.add_argument("--github-token", type=str, default="fake_token",
      help="GitHub token when using --github")
    parser.add_argument("--jira-url", type=str, default="https://issues.couchbase.com",
      help="JIRA URL when using --github")
    parser.add_argument("--jira-username", type=str, default="fake_username",
      help="JIRA username when using --github")
    parser.add_argument("--jira-api-token", type=str, default="fake_token",
      help="JIRA API token when using --github")
    args = parser.parse_args()

    if args.project == "manifest":
      script = "restricted-manifest-check"
    else:
      script = "restricted-branch-check"

    env = os.environ

    # Setup environment variables for github/gerrit
    if args.github:
        print("Simulating GitHub Actions environment")
        env.update({
            "GITHUB_BASE_REF": args.branch,
            "GITHUB_REPOSITORY": args.project,
            "PR_NUMBER": args.pr_number,
            "GITHUB_TOKEN": args.github_token,
            "JIRA_URL": args.jira_url,
            "JIRA_USERNAME": args.jira_username,
            "JIRA_API_TOKEN": args.jira_api_token
        })
    else:
        print("Simulating Gerrit environment")
        refspec = f"refs/changes/{args.change[-2:]}/{args.change}/{args.patchset}"
        # To base64-encode the commit message, we have to first encode the
        # string to utf-8 bytes, then base64-encode the bytes to new utf-8
        # encoded bytes, then decode these bytes back to string.
        b64_message = base64.b64encode(args.message.encode("utf-8")).decode("utf-8")
        env.update({
            "GERRIT_PROJECT": args.project,
            "GERRIT_BRANCH": args.branch,
            "GERRIT_CHANGE_COMMIT_MESSAGE": b64_message,
            "GERRIT_HOST": "review.couchbase.org",
            "GERRIT_PORT": "29418",
            "GERRIT_REFSPEC": refspec,
            "GERRIT_CHANGE_URL": f"http://review.couchbase.org/{args.change}",
            "GERRIT_PATCHSET_NUMBER": args.patchset,
            "GERRIT_EVENT_TYPE": "comment-added"
        })

    retval = subprocess.call(["uv", "run", script, "-p", args.manifest_project], env=env)
    print(f"\n\nReturn code from {script}: {retval}")
