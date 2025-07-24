#!/usr/bin/env python3

import argparse
import base64
import html
import os
import re
import sys
import urllib

from jira_util import connect_jira, get_tickets

script_dir = os.path.dirname(os.path.abspath(__file__))
build_from_manifest_path = os.path.abspath(os.path.join(script_dir, "..", "build-from-manifest"))
if build_from_manifest_path not in sys.path:
    sys.path.insert(0, build_from_manifest_path)
from manifest_util import scan_manifests

"""
Intended to run as a Gerrit trigger or github action.

When triggered via gerrit, the following environment variables must be set
as Gerrit plugin would:
  GERRIT_PROJECT   GERRIT_BRANCH   GERRIT_CHANGE_COMMIT_MESSAGE
  GERRIT_CHANGE_URL   GERRIT_PATCHSET_NUMBER  GERRIT_EVENT_TYPE

When triggered via github action, the following environment variables must be set:
  GITHUB_BASE_REF   GITHUB_REPOSITORY   PR_NUMBER   GITHUB_TOKEN
  JIRA_URL   JIRA_USERNAME   JIRA_API_TOKEN
"""

# Global variables to be populated by setup_environment()
TRIGGER = None
PROJECT = None
BRANCH = None
COMMIT_MSG = None

# Values for outputting in HTML template (initialized later)
OUTPUT = {}

# Name for output HTML file
html_filename = "restricted.html"


def sanitize_for_template(value):
    """
    Sanitize user input for safe template rendering to prevent injection attacks
    """
    if value is None:
        return ""
    # HTML escape the value and limit length to prevent DoS
    sanitized = html.escape(str(value)[:10000])
    return sanitized


def format_release_with_version(release_name, version):
    """
    Format release name with version in parentheses if version is available
    """
    if version:
        return f"{release_name} ({version})"
    return release_name



def setup_environment():
    """
    Set up global variables based on the execution environment
    """
    global TRIGGER, PROJECT, BRANCH, COMMIT_MSG, OUTPUT

    if os.getenv("GERRIT_PROJECT"):
        TRIGGER = "GERRIT"
        PROJECT = os.environ["GERRIT_PROJECT"]
        BRANCH = os.environ["GERRIT_BRANCH"]
        COMMIT_MSG = base64.b64decode(
            os.environ["GERRIT_CHANGE_COMMIT_MESSAGE"]).decode("utf-8")
    elif os.getenv("GITHUB_REPOSITORY"):
        TRIGGER = "GITHUB"
        BASE_BRANCH = os.getenv("GITHUB_BASE_REF")
        REPO = os.getenv("GITHUB_REPOSITORY")
        PR_NUMBER = os.getenv("PR_NUMBER")
        GH_TOKEN = os.getenv("GITHUB_TOKEN")
        JIRA_URL = os.getenv("JIRA_URL")
        JIRA_USERNAME = os.getenv("JIRA_USERNAME")
        JIRA_TOKEN = os.getenv("JIRA_API_TOKEN")

        # For GitHub, we need to set PROJECT and BRANCH correctly
        try:
            PROJECT = REPO.split("/")[1]
            BRANCH = BASE_BRANCH

            # Get PR title from environment variable (passed from workflow)
            PR_TITLE = os.getenv("PR_TITLE")
            if not PR_TITLE:
                print(f"::error::PR_TITLE environment variable is required but not provided")
                sys.exit(1)

            # Limit title length to prevent abuse (same as original API call logic)
            if len(PR_TITLE) > 100:
                COMMIT_MSG = PR_TITLE[:100] + "..."
            else:
                COMMIT_MSG = PR_TITLE

        except Exception as e:
            print(f"::error::Failed to process GitHub PR information: {e}")
            sys.exit(1)
    else:
        print("Error: Required environment variables not set")
        print("\nUsage:")
        print("  This script checks if changes to a branch are restricted by release policy.")
        print("\nRunning with Gerrit requires:")
        print("  GERRIT_PROJECT, GERRIT_BRANCH, GERRIT_CHANGE_COMMIT_MESSAGE")
        print("  GERRIT_CHANGE_URL, GERRIT_PATCHSET_NUMBER, GERRIT_EVENT_TYPE")
        print("\nRunning with GitHub Actions requires:")
        print("  GITHUB_BASE_REF, GITHUB_REPOSITORY, PR_NUMBER, PR_TITLE, GITHUB_TOKEN")
        print("  JIRA_URL, JIRA_USERNAME, JIRA_API_TOKEN")
        print("\nSee documentation for more details.")
        sys.exit(1)

    # Initialize OUTPUT with globals
    OUTPUT.update(globals())


def check_branch_in_manifest(meta):
    """
    Returns true if the PRODUCT/BRANCH are listed in the named manifest
    """
    print(f"Checking manifest {meta['manifest_path']}")

    manifest_et = meta["_manifest"]
    project_et = manifest_et.find("./project[@name='{}']".format(PROJECT))
    if project_et is None:
        project_et = manifest_et.find("./extend-project[@name='{}']".format(PROJECT))
        if project_et is None:
            print("project {} not found".format(PROJECT))
            return False

    # Compute the default branch for the manifest
    default_branch = "master"
    default_et = manifest_et.find("./default")
    if default_et is not None:
        default_branch = default_et.get("branch", "master")

    # Pull out the branch for the given project
    project_branch = project_et.get("revision", default_branch)
    if project_branch != BRANCH:
        print("project {} on branch {}, not {}".format(
            PROJECT, project_branch, BRANCH)
        )
        return False
    return True


def can_bypass_restriction(ticket, jira):
    """
    Given a Jira ticket ID, returns true if 'doc-change-only' and/or
    'test-change-only' labels are present, or false if neither are
    found
    """
    bypass_labels = [
        'doc-change-only',
        'test-change-only',
        'analytics-compat-jars'
    ]
    try:
        jira_ticket = jira.issue(ticket)
        return any(label in bypass_labels for label in jira_ticket.raw['fields']['labels'])
    except:
        # If the above jira call failed, it was most likely due to the
        # message naming a non-existent ticket eg. due to a typo or
        # similar. We don't want to fail with an error about retrieving
        # labels; just assume the non-existent ticket didn't have any of
        # the approved labels.
        return False


def get_approved_tickets(approval_ticket, jira):
    """
    Given a Jira approval ticket ID, return all linked ticket IDs
    """
    jira_ticket = jira.issue(approval_ticket)
    depends = [
        link.outwardIssue.key for link in jira_ticket.fields.issuelinks
        if hasattr(link, "outwardIssue")
    ]
    relates = [
        link.inwardIssue.key for link in jira_ticket.fields.issuelinks
        if hasattr(link, "inwardIssue")
    ]
    subtasks = [subtask.key for subtask in jira_ticket.fields.subtasks]
    return depends + relates + subtasks + [approval_ticket]


def validate_change_in_ticket(meta):
    """
    Checks the commit message for a ticket name, and verifies it with the the
    approval ticket for the restricted manifest
    """
    global COMMIT_MSG
    approval_ticket = meta.get("approval_ticket")
    # We require a ticket to be named either on the first line of the
    # commit message OR in an Ext-ref: footer line. For the time being
    # we don't enforce footers being at the end of the commit message;
    # any line that starts with Ext-ref: will do.
    msg_lines = ""
    for i, line in enumerate(COMMIT_MSG.split('\n')):
        if i == 0 or line.startswith("Ext-ref:"):
            msg_lines += f"{line}\n"
    fix_tickets = get_tickets(msg_lines)
    if len(fix_tickets) == 0:
        OUTPUT["REASON"] = "the commit message does not name a ticket"
        return False

    # Now get list of approved tickets from approval ticket, and ensure
    # all "fixed" tickets are approved.
    jira = connect_jira()
    approved_tickets = get_approved_tickets(approval_ticket, jira)
    for tick in fix_tickets:
        if tick not in approved_tickets and not can_bypass_restriction(tick, jira):
            # Ok, this fixed ticket isn't approved in approval ticket
            # nor does it contain a label for bypassing this check.
            # Populate the OUTPUT map for the HTML and email templates.
            # Need to format release_name with version for consistent output
            release_name = meta.get("release_name")
            version = meta.get("version", "")
            formatted_release = format_release_with_version(release_name, version)

            OUTPUT["REASON"] = "ticket {} is not approved for {} " \
                "(see approval ticket {})".format(
                    tick, formatted_release, approval_ticket
            )
            return False
    return True


def output_report_gerrit(meta):
    """
    Outputs HTML report explaining why change was restricted for Gerrit,
    and exits with non-0 return value
    """
    OUTPUT["RELEASE_NAME"] = meta.get("release_name")
    OUTPUT["APPROVAL_TICKET"] = meta.get("approval_ticket")
    OUTPUT.update(os.environ)
    # Specialized mailto: URL for new branch request
    tmpldir = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(tmpldir, "mailto_url.tmpl")) as tmplfile:
        mailto_url = tmplfile.read().strip().format(**OUTPUT)
        print(mailto_url)
        OUTPUT["MAILTO_URL"] = urllib.parse.quote(mailto_url, ":@=&?")
    with open(html_filename, "w") as html:
        with open(os.path.join(tmpldir, "restricted.html.tmpl")) as tmplfile:
            tmpl = tmplfile.read()
        html.write(tmpl.format(**OUTPUT))
        print("\n\n\n*********\nRESTRICTED: {}\n*********\n\n\n".format(
            OUTPUT["REASON"]
        ))
        sys.exit(5)


def output_report_github(meta):
    """
    Outputs GitHub Actions friendly restriction report,
    and exits with non-0 return value
    """
    release_name = meta.get("release_name")
    version = meta.get("version", "")
    formatted_release = format_release_with_version(release_name, version)

    approval_ticket = meta.get("approval_ticket")
    reason = OUTPUT.get("REASON")

    safe_reason = sanitize_for_template(reason)
    safe_release = sanitize_for_template(formatted_release)
    safe_approval = sanitize_for_template(approval_ticket)

    print(f"::error::RESTRICTED: {safe_reason}")

    print(f"❌ Pull request is restricted: {safe_reason}")
    print(f"   Release: {safe_release}")
    print(f"   Approval ticket: {safe_approval}")

    # Handle specific cases with helpful messages
    if "commit message does not name a ticket" in safe_reason:
        print(f"   Please include a JIRA ticket reference in the PR title.")
    elif "ticket" in safe_reason and "not approved" in safe_reason:
        print(f"   Please ensure the ticket is linked in the approval ticket {safe_approval} before merging.")

    # Output structured information for GitHub Actions summary
    github_output_file = os.environ.get("GITHUB_OUTPUT")
    if github_output_file:
        try:
            with open(github_output_file, "a") as f:
                f.write(f"restriction_reason={safe_reason}\n")
                f.write(f"restriction_release={safe_release}\n")
                f.write(f"restriction_approval_ticket={safe_approval}\n")

                # Determine the type of restriction for better messaging
                if "commit message does not name a ticket" in safe_reason:
                    f.write("restriction_type=missing_ticket\n")
                elif "ticket" in safe_reason and "not approved" in safe_reason:
                    f.write("restriction_type=unapproved_ticket\n")
                else:
                    f.write("restriction_type=other\n")
        except Exception as e:
            print(f"::warning::Failed to write to GITHUB_OUTPUT: {e}")

    sys.exit(5)


def output_report(meta):
    """
    Outputs report explaining why change was restricted based on trigger environment,
    and exits with non-0 return value
    """
    if TRIGGER == "GERRIT":
        output_report_gerrit(meta)
    else:
        output_report_github(meta)


def failed_output_gerrit(exc_message):
    """
    Outputs HTML page that gives the reason the program unexpectedly exited for Gerrit,
    and exits with a non-0 return value
    """
    tmpldir = os.path.dirname(os.path.abspath(__file__))
    with open(html_filename, "w") as html:
        with open(os.path.join(tmpldir, "rest_failed.html.tmpl")) as tmplfile:
            tmpl = tmplfile.read()
        html.write(tmpl.format(EXC_MESSAGE=exc_message))

        print("\n\n\n*******\nFAILURE: {}\n*******\n\n\n".format(
            exc_message
        ))
        sys.exit(6)


def failed_output_github(exc_message):
    """
    Outputs GitHub Actions friendly failure message,
    and exits with a non-0 return value
    """
    safe_message = sanitize_for_template(exc_message)
    print(f"::error::FAILURE: Restriction check failed")
    print(f"❌ restricted branch check encountered an error. Check logs for details.")
    sys.exit(6)


def failed_output_page(exc_message):
    """
    Outputs failure message based on the trigger environment (Gerrit or GitHub Actions),
    and exits with a non-0 return value
    """
    if TRIGGER == "GERRIT":
        failed_output_gerrit(exc_message)
    else:
        failed_output_github(exc_message)


def real_main():
    """
    Main function that performs the actual restriction check
    """
    # Set up environment variables first
    setup_environment()

    # Command-line args
    parser = argparse.ArgumentParser()
    parser.add_argument("-p", "--manifest-project", type=str,
                        default="ssh://git@github.com/couchbase/manifest",
                        help="Alternate Git project for manifest")
    args = parser.parse_args()

    # In GitHub Actions mode, look for the manifest repo in the workspace
    if TRIGGER == "GITHUB":
        workspace_root = os.environ.get("GITHUB_WORKSPACE", os.getcwd())
        expected_manifest = os.path.join(workspace_root, "manifest")
        local_manifest = os.path.realpath(expected_manifest)

        # Ensure the resolved path is within the expected workspace
        workspace_real = os.path.realpath(workspace_root)
        if not local_manifest.startswith(workspace_real):
            print(f"::error::Security violation: Manifest path outside workspace")
            sys.exit(1)

        if os.path.isdir(local_manifest):
            print(f"Using manifest repository: {local_manifest}")
            manifest_project = local_manifest
        else:
            print(f"::error::Fatal error: Manifest repository not found at {local_manifest}")
            print(f"❌ Expected manifest repository at {local_manifest} but directory doesn't exist.")
            sys.exit(1)
    else:
        manifest_project = args.manifest_project

    # Clean out report file
    if os.path.exists(html_filename):
        os.remove(html_filename)

    # Collect all restricted manifests that reference this branch
    manifests = scan_manifests(manifest_project)
    restricted_manifests = []
    for manifest in manifests:
        meta = manifests[manifest]
        if meta.get("restricted"):
            approval_ticket = meta.get("approval_ticket")
            if approval_ticket is None:
                print("no approval ticket for restricted manifest {}".format(
                    manifest
                ))
                continue

            # Also see if projects are specifically excluded from check for this manifest
            unrestricted_projects = meta.get("unrestricted_projects", [])
            if PROJECT in unrestricted_projects:
                print("Project {} is unrestricted in manifest {}".format(
                    PROJECT, manifest
                ))
                continue

            if not check_branch_in_manifest(meta):
                continue

            # Ok, this proposal is to a branch in a restricted manifest
            restricted_manifests.append(manifest)
            print("Project: {} Branch: {} is in restricted manifest: "
                  "{}".format(PROJECT, BRANCH, manifest))

    # Now *remove* any restricted manifests that are the parent of any other
    # restricted manifests in the list. Logic: if a change is approved for a
    # branch manifest B, it is implicitly approved for its parent A.
    # Conversely, even if it's approved for A, it cannot go into B. Therefore
    # we don't care whether it's approved for A or not.
    restricted_children = list(restricted_manifests)
    for manifest in restricted_manifests:
        print("....looking at {}".format(manifest))
        parent = manifests[manifest].get("parent")
        print("....parent is {}".format(parent))
        if parent in restricted_children:
            print("Not checking manifest {} because it is a parent "
                  "of {}".format(parent, manifest))
            restricted_children.remove(parent)

    # Now, iterate through all restricted manifests that we have left,
    # and ensure this ticket is approved for each.
    for manifest in restricted_children:
        if not validate_change_in_ticket(manifests[manifest]):
            OUTPUT["MANIFEST"] = manifest
            output_report(manifests[manifest])

    # If we get here, the change is allowed!
    # Output "all clear" message if no restricted branches were checked,
    # or if they were checked and approved.
    if restricted_manifests:
        if TRIGGER == "GERRIT":
            print("\n\n\n*********\nAPPROVED: Commit is approved for all "
                  "restricted manifests\n*********\n\n\n")
        else:
            print("::notice::APPROVED: Pull request is approved for all restricted manifests")
            print("✅ All checks passed. All JIRA tickets referenced in commits are approved for all restricted manifests.")

            # Output success information for GitHub Actions summary
            github_output_file = os.environ.get("GITHUB_OUTPUT")
            if github_output_file:
                try:
                    with open(github_output_file, "a") as f:
                        f.write(f"checked_manifests={','.join(restricted_manifests)}\n")
                        f.write("check_result=approved\n")
                except Exception as e:
                    print(f"::warning::Failed to write success info to GITHUB_OUTPUT: {e}")
    else:
        if TRIGGER == "GERRIT":
            # This is the common case where the change was not to any restricted
            # branches. Normally we want Jenkins to skip voting entirely in this
            # case, to prevent excessive Gerrit comment spam. We indicate this by
            # outputting the word "SILENT". However, if this check was triggered
            # by an explicit "check approval" Gerrit comment, we need to ensure
            # it is not silent in any case.
            silent = " (SILENT)"
            if os.environ.get("GERRIT_EVENT_TYPE") == "comment-added":
                silent = ""
            print("\n\n\n*********\nUNRESTRICTED{}: Branch is in no restricted "
                  "manifests\n*********\n\n\n".format(silent))
        else:
            print("::notice::UNRESTRICTED: Branch is in no restricted manifests")
            print("✅ Branch is not part of any restricted release manifest. Skipping extra checks.")

            # Output success information for GitHub Actions summary
            github_output_file = os.environ.get("GITHUB_OUTPUT")
            if github_output_file:
                try:
                    with open(github_output_file, "a") as f:
                        f.write(f"checked_branch={BRANCH}\n")
                        f.write(f"checked_project={PROJECT}\n")
                        f.write("check_result=unrestricted\n")
                except Exception as e:
                    print(f"::warning::Failed to write success info to GITHUB_OUTPUT: {e}")

def main():
    """
    Entry point with error handling
    """
    # This is a MAJOR hack right now to try to ensure something
    # is usefully printed by the program even if an unexpected
    # exception occurs; further refinement should check for
    # specific exceptions and handle appropriately as needed
    try:
        real_main()
    except Exception as exc:
        failed_output_page(sys.exc_info()[1])

if __name__ == "__main__":
    main()
