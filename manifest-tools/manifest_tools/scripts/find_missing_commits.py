#!/usr/bin/env python3.6
"""
Compare two manifests from a given product to see if there are any
potential commits in the older manifest which did not get included
into the newer manifest.  This will assist in determining if needed
fixes or changes have been overlooked being added to newer releases.
The form of the manifest filenames passed is a relative path based
on their location in the manifest repository (e.g. released/4.6.1.xml).
"""
import argparse
import concurrent.futures
import contextlib
import dulwich.patch
import dulwich.porcelain
import dulwich.repo
import functools
import logging
import os
import pathlib
import io
import json
import re
import shutil
import subprocess
import sys
import threading
import traceback
import xml.etree.ElementTree as ET

from collections import defaultdict
from itertools import combinations
from multiprocessing import cpu_count
from packaging.version import Version
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError
from thefuzz import fuzz
from time import sleep

from manifest_tools.scripts.jira_util import connect_jira, get_tickets


slack_oauth_token = os.getenv("SLACK_OAUTH_TOKEN")

message_template = """
Hi {author},

The commit checker has identified commits authored by you that appear to be missing in subsequent version(s) of {product}.

Please review the list below and merge forward as necessary. If any of these are false positives, contact the build team to request an exclusion.
"""


def default_dict_factory():
    return defaultdict(default_dict_factory)


@contextlib.contextmanager
def pushd(new_dir):
    old_dir = os.getcwd()
    os.chdir(new_dir)
    try:
        yield
    finally:
        os.chdir(old_dir)


class MissingCommits:
    # Pre-compiled regex for long SHAs
    long_sha_regex = re.compile(r'[0-9a-f]{40}')

    # Pre-compiled regex for short SHAs
    short_sha_regex = re.compile(r'[0-9a-f]{7,10}')

    # Pre-compiled regex for tag reference
    tag_regex = re.compile(r'refs/tags/.*')

    # Pre-compiled regex for semver(ish) strings
    semver_regex = re.compile(r'^(\d+\.)*\d+$')

    # Pre-compiled regexes for backport substrings - we strip anything inside
    # [] as the format varies
    backport_regex = re.compile(r'\[.*?\][\s:]*')

    # After removing potential backport substrings, we strip out all non alpha
    # numeric characters to account for variances in punctuation, spaces etc.
    normalize_regex = re.compile(r'[^a-zA-Z0-9]')

    # Matched commits are categorised, the order here dictates the order they
    # will be shown in when running with DEBUG=true
    match_types = ["Backport", "Date match", "Diff match", "Summary match"]

    def __init__(self, logger, product, manifest_dir, manifest_repo,
                 reporef_dir, targeted_projects, debug, show_matches,
                 notify):
        """
        Store key information into instance attributes and determine
        path of 'repo' program
        """

        self.log = logger
        self.debug = debug
        self.show_matches = show_matches
        self.notify = notify

        self.sha_lock = threading.Lock()
        self.date_lock = threading.Lock()

        self.total_missing_commits = 0
        self.matched_commits = 0

        self.product = product
        self.product_dir = pathlib.Path(product)
        self.manifest_repo = manifest_repo
        self.manifest_branch = "main" if product == "sync_gateway" else "master"
        self.reporef_dir = reporef_dir
        self.targeted_projects = [project.strip() for project in targeted_projects.split(",")] if targeted_projects else None

        self.commits = default_dict_factory()
        self.long_shas = {}
        self.commit_authors_and_dates = {}

        # Projects we don't care about
        self.ignore_projects = [
            'testrunner', 'libcouchbase', 'product-texts', 'product-metadata']

        self.git_bin = shutil.which('git')
        self.repo_bin = shutil.which('repo')

        self.slack_client = WebClient(token=slack_oauth_token)
        self.manifests = self.get_manifests(product, manifest_dir)

        self.notified_users = []
        self.skipped_users = []

        # We check jira and ignore tickets which are flagged "is a backport of"
        # a ticket in the newer release
        try:
            self.log.debug("Connecting to Jira")
            self.jira = connect_jira()
        except Exception as exc:
            traceback.print_exc()
            self.log.critical("Jira connection failed")
            raise RuntimeError("Jira connection failed") from exc

    def __str__(self):
        """
        Return a formatted string with the missing commits (and matches if
        debug is enabled)
        """

        def header(text, count):
            title = f"{text}: "
            separator = f"{'=' * (len(title) + len(str(count)))}{os.linesep}"
            return f"{os.linesep}{separator}{title}{count}{os.linesep}{separator}"

        output = ""
        projects_not_missing_commits = []

        if self.total_missing_commits > 0:
            output += header("MISSING COMMITS", self.total_missing_commits)
            for project, info in self.commits[self.product].items():
                commits = info.get("Missing", {})
                if commits:
                    output += f"{os.linesep}Project {project} - missing: {len(commits)}{os.linesep}"
                    if commits:
                        for sha, match_details in commits.items():
                            output += f"    [{sha[:7]}] {match_details['message']}{os.linesep}"
                else:
                    projects_not_missing_commits.append(project)

            if projects_not_missing_commits:
                output += f"{os.linesep}Projects without missing commits:{os.linesep}"
                for project in projects_not_missing_commits:
                    output += f"    {project}{os.linesep}"

        if self.matched_commits > 0 and self.show_matches:
            output += header("MATCHES", self.matched_commits)
            for project, info in self.commits[self.product].items():
                if any(info.get(match_type) for match_type in self.match_types):
                    output += f"{os.linesep}Project {project}:{os.linesep}"

                for match_type in self.match_types:
                    matches = info.get(match_type, {})
                    if matches:
                        padding = len(
                            max(self.match_types, key=len)) - len(match_type)
                        for sha, match_details in matches.items():
                            output += f"    {' ' * padding}{match_type} [{sha[:7]}] {match_details['message']} {os.linesep}"
                            if match_type == "Backport":
                                for matched_sha, matched_message in match_details['backports'].items():
                                    output += f"    {' ' * (len(match_type)+padding)} [{matched_sha[:7]}] {matched_message}{os.linesep}"
                            else:
                                for matched_sha, matched_message in match_details['matched'].items():
                                    output += f"    {' ' * (len(match_type)+padding)} [{matched_sha[:7]}] {matched_message}{os.linesep}"
            output += os.linesep

        return output

    def fix_repo_cmd(self):
        """
        Remove reliance on setenv, to hide warnings on centos:7 where ssh
        is too old
        """
        file_path = ".repo/repo/ssh.py"

        with open(file_path, "r") as f:
            lines = f.readlines()

        new_lines = []
        for _, line in enumerate(lines):
            # in ssh.py, we need to remove both the SetEnv line and the
            # line immediately preceeding it
            if "SetEnv" in line:
                if new_lines and new_lines[-1].strip() == '"-o",':
                    new_lines.pop()
                continue
            new_lines.append(line)

        with open(file_path, "w") as f:
            f.writelines(new_lines)

    def send_alert(self, email, text):
        try:
            user = self.slack_client.users_lookupByEmail(email=email)['user']['id']
            channel = self.slack_client.conversations_open(users=user)['channel']['id']
            self.slack_client.chat_postMessage(
                channel=channel,
                text=text
            )
            if email not in self.notified_users:
                self.notified_users.append(email)
        except SlackApiError as e:
            self.log.error(f"Failed to message {email}: {e.response['error']}")

    def check_call(self, cmd, cwd=None, stdin=None, stdout=None, stderr=None):
        self.log.debug(f"check_call: Running {' '.join([str(c) for c in cmd])} in {str(os.getcwd())} with cwd {str(cwd)}")
        subprocess.check_call(
            cmd,
            cwd=cwd,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr
        )

    def check_output(self, cmd, cwd=None, stdin=None, stderr=None):
        self.log.debug(f"check_output: Running {' '.join([str(c) for c in cmd])} in {str(os.getcwd())} with cwd {str(cwd)}")
        return subprocess.check_output(
            cmd,
            cwd=cwd,
            stdin=stdin,
            stderr=stderr
        )

    def Popen(self, cmd, cwd=os.getcwd(), stdin=None, stdout=None, stderr=None):
        self.log.debug(f"popen: Running {' '.join([str(c) for c in cmd])} in {str(os.getcwd())} with cwd {str(cwd)}")
        return subprocess.Popen(
            cmd,
            cwd=cwd,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr
        )

    def get_manifests(self, product, manifest_dir):
        """
        Get a list of active manifests for a specific product
        """
        def filter_latest_semvers(semver_list):
            """ Filter out all but the latest semver for each major.minor """
            semver_groups = defaultdict(list)
            default_version = None
            default_semver = None
            for semver in semver_list:
                if re.match(self.semver_regex, os.path.basename(semver).split(".xml")[0]):
                    version = Version(os.path.basename(semver).split(".xml")[0])
                    major_minor = f"{version.major}.{version.minor}"
                    semver_groups[major_minor].append((version, semver))
                else:
                    if semver == "manifest/default.xml" and product == "sync_gateway":
                        tree = ET.parse(manifest_dir / "manifest/default.xml")
                        root = tree.getroot()
                        build = root.find("project[@name='build']")
                        if build:
                            for annotation in build.findall("annotation"):
                                if annotation.get("name") == "VERSION":
                                    default_version = Version(annotation.get("value"))
                                    default_semver = semver
            latest_versions = [
                max(versions, key=lambda x: x[0])[1] for versions in semver_groups.values()
            ]
            if default_version and default_semver:
                inserted = False
                for i, semver in enumerate(latest_versions):
                    version = Version(os.path.basename(semver).split(".xml")[0])
                    if default_version < version:
                        latest_versions.insert(i, default_semver)
                        inserted = True
                        break
                if not inserted:
                    latest_versions.append(default_semver)
            return latest_versions

        manifests = []

        if product == "sync_gateway":
            product_config = manifest_dir / "manifest/product-config.json"
        else:
            product_config = manifest_dir / product / "product-config.json"

        with open(product_config) as f:
            data = json.load(f)
            if product == "sync_gateway":
                raw_manifest_list = list(data["manifests"].keys())[::-1]
            else:
                raw_manifest_list = list(data["manifests"].keys())

            for manifest in raw_manifest_list:
                if data["manifests"][manifest].get("do-build", True):
                    if product == "couchbase-server":
                        # For couchbase-server, skip any manifest that has a digit in the name
                        if any(char.isdigit() for char in os.path.basename(manifest)):
                            continue
                    manifests.append(manifest)

        active_manifests = []

        for node_name in manifests:
            if product == "couchbase-server" and any(char.isdigit() for char in node_name):
                # Ignore any couchbase-server manifest with a digit in the
                # name - not interested in numbered versions currently
                continue
            else:
                active_manifests.append(node_name)

        active_manifests.reverse()

        if product == "sync_gateway":
            active_manifests = filter_latest_semvers(active_manifests)

        return active_manifests

    def project_url(self, project_name):
        """
        Retrieve the URL for a given project in the manifest
        """
        manifest_path = f"{self.product}/.repo/manifests/{self.new_manifest}"

        tree = ET.parse(f"{manifest_path}")
        root = tree.getroot()

        remotes = {}
        for remote in root.findall("remote"):
            name = remote.get('name')
            fetch = remote.get('fetch')
            remotes[name] = fetch

        default_remote = None
        default = root.find("default")
        if default is not None:
            default_remote = default.get("remote")

        project = None
        for p in root.findall("project"):
            if p.get("name") == project_name:
                project = p
                break
        if project is None:
            raise ValueError(
                f"Project {project_name} not found in {manifest_path}")

        project_remote = project.get("remote") or default_remote
        if project_remote not in remotes:
            raise ValueError(
                f"Remote {project_remote} not found for project {project_name}")

        fetch_url = remotes[project_remote]
        url = f"{fetch_url.rstrip('/')}/{project.get('name')}"

        return url.replace("ssh://git@", "https://")

    def get_jira_ticket(self, ticket):
        """
        Fetch and return a specified jira ticket
        """
        try:
            self.log.debug(f"Fetching Jira ticket {ticket}")
            issue = self.jira.issue(ticket)
            return issue
        except Exception as exc:
            traceback.print_exc()
            raise RuntimeError(
                f"Jira ticket retrieval failed for {ticket}") from exc

    def identify_missing_commits(self, old_manifest, new_manifest):
        """
        Identifies and outputs missing commits

        This method performs the following steps:
        1. Syncs the manifest
        2. Calculates the difference between manifests
        3. Creates a dictionary of changed projects
        4. Performs commit diffs
        5. Prints the result
        """

        self.log.info(
            f"Checking for missing commits between {old_manifest} and {new_manifest}")
        self.old_manifest = old_manifest
        self.new_manifest = new_manifest
        self.repo_sync()
        manifest_diff = self.diff_manifests()
        self.ignored_commits = self.get_ignored_commits()

        changes = dict()
        # Create dictionary with all the relevant changes; this avoids
        # any added or removed projects that were not part of a merge
        # process at some point in the past
        for entry in manifest_diff:
            if entry.startswith('C '):
                _, repo_path, old_commit, new_commit = entry.split()
                changes[repo_path] = ('changed', old_commit, new_commit)

        # Perform commit diffs, handling merged projects by diffing
        # the merged project against each of the projects the were
        # merged into it
        for repo_path, change_info in changes.items():
            if self.targeted_projects and repo_path.split("/")[-1] not in self.targeted_projects:
                continue
            if change_info[0] == 'changed':
                change_info = change_info[1:]
                self.show_needed_commits(repo_path, change_info)
            elif change_info[0] == 'added':
                _, new_commit, new_diff = change_info
                for pre in self.merge_map[repo_path]:
                    _, old_commit, old_diff = changes.get(
                        pre, (None, None, None))
                    if old_commit is not None:
                        change_info = (old_commit, new_commit,
                                       old_diff, new_diff)
                        self.show_needed_commits(repo_path, change_info)
        print(self)

    def backports_of(self, tickets, retries=3):
        """
        For a list of tickets, gather any outward links flagged "is a
        backport of" in Jira and return a combined listing of the ticket
        references
        """

        backports = []
        for ticket in tickets:
            for _ in range(retries):
                try:
                    jira_ticket = self.get_jira_ticket(ticket)
                    # Connection failures don't seem to raise an error, so we just
                    # check if jira_ticket came back ok and retry 3 times if not
                    # before giving up
                    if not jira_ticket:
                        sleep(1)
                        return self.backports_of(tickets, retries-1)
                    for issuelink in jira_ticket.raw["fields"]["issuelinks"]:
                        if issuelink["type"]["outward"] == "is a backport of":
                            # Ensure we're looking at the actual backport ticket,
                            # not a ticket that was itself backported
                            if "outwardIssue" in issuelink:
                                backports.append(
                                    issuelink["outwardIssue"]["key"])
                    # If we got here we can break out of the retry loop and
                    # move on to the next ticket
                    break
                except Exception as exc:
                    self.log.error(
                        f"Jira ticket retrieval failed for {ticket}")
            else:
                # If we got here, we ran out of retries without hitting the
                # break
                self.log.error(f"Jira ticket retrieval failed for {ticket}")

        return backports

    def repo_sync(self):
        """
        Initialize and sync a repo checkout based on the target
        manifest; generate a new manifest with fixed SHAs in case
        the target contains branches (e.g. master) via the command
        'repo manifest -r' so 'git log' will work properly
        """

        self.repo_bin = shutil.which('repo')
        # Create a 'product' directory to contain the repo checkout
        if self.product_dir.exists():
            self.log.debug(f'"{self.product_dir}" exists, removing...')
            try:
                if not self.product_dir.is_dir():
                    self.product_dir.unlink()
                else:
                    shutil.rmtree(self.product_dir)
            except OSError as exc:
                traceback.print_exc()
                raise RuntimeError(
                    f'Unable to delete "{self.product_dir}" file/link: '
                    f'{exc.message}'
                ) from exc
        self.product_dir.mkdir(parents=True, exist_ok=True)

        try:
            cmd = [self.repo_bin, 'init', '-u',
                   self.manifest_repo,
                   '-g', 'all', '-m', self.new_manifest]
            if self.reporef_dir is not None:
                cmd.extend(['--reference', str(self.reporef_dir)])

            self.check_output(
                cmd,
                cwd=self.product_dir,
                stderr=subprocess.STDOUT
            )
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(
                f'The "repo init" command failed: {exc.output}') from exc

        # From now on, use the "repo" wrapper from the .repo directory,
        # to prevent "A new version is available" warning messages.
        # This assumes that all "repo" commands will be invoked with
        # cwd=self.product_dir, so this relative path will work.
        self.repo_bin = os.path.join(".repo", "repo", "repo")

        try:
            cmd = [self.repo_bin, 'sync',
                    f'--jobs={cpu_count()}', '--force-sync']
            self.check_output(
                cmd,
                cwd=self.product_dir, stderr=subprocess.STDOUT
            )
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(
                f'The "repo sync" command failed: {exc.output}') from exc

        # This is needed for manifests with projects not locked down
        # (e.g. spock.xml)
        try:
            with open('new.xml', 'w') as fh:
                self.check_call(
                    [self.repo_bin, 'manifest', '-r'],
                    stdout=fh, cwd=self.product_dir
                )
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(
                f'The "repo manifest -r" command failed: {exc.output}') from exc

    def diff_manifests(self):
        """
        Generate the diffs between the two manifests via the command
        'repo diffmanifests'.  Only return the project lines, not
        the actual commit differences.
        """

        new_xml = pathlib.Path('new.xml').resolve()

        try:
            diffs = self.check_output(
                [self.repo_bin, 'diffmanifests', '--raw',
                 self.old_manifest, new_xml],
                cwd=self.product_dir, stderr=subprocess.STDOUT
            ).decode()
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(
                f'The "repo diffmanifests" command failed: {exc.output}') from exc

        return [
            line for line in diffs.strip().split('\n')
            if not line.startswith(' ')
        ]

    def get_author_and_date(self, repo_path, commit_sha):
        """
        Get the author date for a specific SHA
        """

        with self.date_lock:
            if commit_sha in self.commit_authors_and_dates:
                return self.commit_authors_and_dates[commit_sha]

        project_dir = self.product_dir / repo_path
        try:
            (author, date) = self.check_output(
                ['git', 'show', '-s', '--format=%ae|%ai', commit_sha],
                cwd=project_dir
            ).decode().strip().split("|")
            self.commit_authors_and_dates[commit_sha] = (author, date)
            return (author, date)
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(
                f'Failed to retrieve commit date for '
                f'{commit_sha}: {exc.output}') from exc

    def get_commit_details(self, line, repo_path):
        """
        Retrieves the commit details for a given line of git output
        (a sha followed by the subject line of that sha)
        """
        sha, msg = line.split(' ', 1)
        long_sha = self.get_long_sha(repo_path, sha)
        author, date = self.get_author_and_date(repo_path, long_sha)
        diff_changes = self.get_diff_changes(repo_path, long_sha)
        return (sha, msg, author, date, diff_changes)

    def get_diff_changes(self, repo_path, commit_sha):
        """
        Retrieve a diff for a given sha showing only added/removed lines
        """

        project_dir = self.product_dir / repo_path
        repo = dulwich.repo.Repo(str(project_dir.resolve()))

        # Make sure we're working with the full sha, or the lookup below
        # will throw an error
        commit_sha = self.get_long_sha(repo_path, commit_sha)

        obj = repo[bytes(commit_sha, 'utf-8')]

        if isinstance(obj, dulwich.objects.Tag):
            commit = repo[obj.object[1]]
        else:
            commit = obj

        if not isinstance(commit, dulwich.objects.Commit):
            self.log.error(
                f'The object resolved from SHA {commit_sha} in {repo_path} is '
                'not a commit.')
            return []

        if not commit.parents:
            self.log.error(f"No parents on {commit_sha} in {repo_path}")
            return []

        prev_commit = repo[commit.parents[0]]

        fh = io.BytesIO()
        dulwich.patch.write_tree_diff(fh, repo.object_store, prev_commit.tree,
                                      commit.tree)

        return [
            line for line in fh.getvalue().decode(errors='replace').split('\n')
            if line and line.startswith(('+', '-'))
        ]

    def get_long_sha(self, project, commit):
        """
        Find the full SHA from a specified branch/tag/SHA
        """

        # In cache? Just return it
        with self.sha_lock:
            if f"{project}:{commit[:7]}" in self.long_shas:
                return self.long_shas[f"{project}:{commit[:7]}"]

        # Long sha? cache and return
        if MissingCommits.long_sha_regex.fullmatch(commit) is not None:
            self.long_shas[f"{project}:{commit[:7]}"] = commit
            return commit

        # Not a long SHA, so ask git to turn it into one. If 'commit'
        # looks like a short sha, use rev-parse, if it looks like a tag
        # reference, use it directly with show-ref; otherwise, assume it's
        # a branch name, prepend the remote name to disambiguate and use
        # show-ref
        if MissingCommits.short_sha_regex.fullmatch(commit) is not None:
            cmd = "git rev-parse"
            git_ref = commit
        elif MissingCommits.tag_regex.fullmatch(commit) is not None:
            cmd = "git show-ref --hash"
            git_ref = commit
        else:
            # $REPO_REMOTE is set by 'repo forall'
            cmd = "git show-ref --hash"
            git_ref = f'$REPO_REMOTE/{commit}'

        try:
            commit_sha = self.check_output(
                [self.repo_bin, 'forall', project, '-c',
                 f'{cmd} {git_ref}'],
                cwd=self.product_dir, stderr=subprocess.STDOUT
            ).decode().strip()
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(
                f'The "repo forall" command failed: {exc.output}') from exc

        self.long_shas[f"{project}:{commit[:7]}"] = commit_sha
        return commit_sha

    def get_project_name(self, project_dir):
        project_name = self.check_output(
            [self.repo_bin, 'forall', project_dir, '-c',
                f'echo $REPO_PROJECT'],
            cwd=self.product_dir, stderr=subprocess.STDOUT
        ).decode().strip()
        return project_name

    def add_match(self, match_type, project, author, old_sha, old_commit_message, new_sha, new_commit_message, extra_info=None):
        if new_sha not in self.commits[self.product][project][match_type]:
            self.commits[self.product][project][match_type][new_sha] = {
                "present_in": [self.old_manifest, self.new_manifest],
                "message": new_commit_message,
                "author": author,
                "matched": {
                    old_sha: old_commit_message,
                },
                **(extra_info or {})
            }
        else:
            for manifest in [self.old_manifest, self.new_manifest]:
                if manifest not in self.commits[self.product][project][match_type][new_sha]["present_in"]:
                    self.commits[
                        self.product][project][match_type][new_sha]["present_in"].append(manifest)
        self.matched_commits += 1

    def match_date(self, project, new_commit, old_commits):
        """
        Checks if the date of a new commit matches the date of any old commit
        in a list of old commits.
        """

        new_sha, new_commit_message, new_author, new_date, _ = new_commit
        for old_sha, old_commit_message, old_author, old_date, _ in old_commits:
            if old_date == new_date and old_author == new_author:
                self.add_match("Date match", project, old_author, old_sha,
                               old_commit_message, new_sha, new_commit_message)
                return True

    def match_diff(self, project, new_commit, old_commits):
        """
        Fuzzy comparison of two diffs (changes only)
        """

        new_sha, new_commit_message, _, _, new_diff = new_commit
        for old_sha, old_commit_message, old_author, _, old_diff in old_commits:
            if len(new_diff) <= 10:
                threshold = 90
            elif len(new_diff) <= 50:
                threshold = 80
            else:
                threshold = 70
            ratio = fuzz.ratio(new_diff, old_diff)
            if ratio > threshold:
                self.add_match("Diff match", project, old_author, old_sha,
                               old_commit_message, new_sha, new_commit_message, {"ratio": ratio})
                return ratio

    def match_summary(self, project, new_commit, old_commits):
        """
        Matches the summary of a new commit with the summaries of old commits.
        """
        new_sha, new_commit_message, _, _, _ = new_commit
        for old_sha, old_commit_message, old_author, _, _ in old_commits:
            normalized_old_commit_message = re.sub(self.backport_regex, '', re.sub(
                self.normalize_regex, '', old_commit_message)).lower()
            normalized_new_commit_message = re.sub(self.backport_regex, '', re.sub(
                self.normalize_regex, '', new_commit_message)).lower()
            if normalized_old_commit_message == normalized_new_commit_message and len(old_commit_message) > 10:
                self.add_match("Summary match", project, old_author, old_sha,
                               old_commit_message, new_sha, new_commit_message)
                return True

    def get_ignored_commits(self):
        commits = []
        if self.product == "couchbase-server":
            release = os.path.basename(self.new_manifest).split('.')[0]
        elif self.product == "sync_gateway":
            release = ".".join(os.path.basename(self.new_manifest).split('.')[:-1])
        try:
            with open(f"/data/metadata/product-metadata/{self.product}/missing_commits/{release}/ok-missing-commits.txt") as fh:
                for entry in fh.readlines():
                    if entry.startswith('#'):
                        continue   # Skip comments
                    try:
                        _, commit = entry.split()[0:2]
                    except ValueError:
                        self.log.warning(f'Malformed line in ignored commits file, '
                                         f'skipping: {entry}')
                    else:
                        commits.append(commit)
        except FileNotFoundError:
            self.log.warning(f'Ignored commits file /data/metadata/product-metadata/{self.product}/missing_commits/{release}/ok-missing-commits.txt '
                             f'not found.  Continuing...')
        return commits

    def show_needed_commits(self, repo_path, change_info):
        """
        Determine 'missing' commits for a given project based on two commit
        SHAs for the project. This is done by doing a 'git log' on the
        symmetric difference of the two commits in forward and reversed order,
        then comparing the summary content, dates and diffs from the latter to
        find a matching entry in the former, which are all strong indications
        that the commit was properly merged into the project at the time of the
        target manifest.
        Retrieve any possible matches along with any 'missing' commits to
        allow us to determine what might still need to be merged forward.
        """

        # We skip any projects which:
        # - are explicitly ignored
        # - don't match the targeted project (if a project is being targeted)
        # - are third party godeps
        if repo_path in self.ignore_projects or (
            self.targeted_projects and not any(
                re.search(rf'\b{project}\b', repo_path) for project in self.targeted_projects
            ) or (
                repo_path.startswith(
                "godeps") and "couchbase" not in repo_path
            )):
            return

        old_commit, new_commit = change_info
        missing = [
            self.git_bin, 'log', '--oneline', '--cherry-pick',
            '--right-only', '--no-merges'
        ]

        old_commit = self.get_long_sha(repo_path, old_commit)
        new_commit = self.get_long_sha(repo_path, new_commit)

        project_dir = self.product_dir / repo_path

        try:
            old_results = self.check_output(
                missing + [f'{old_commit}...{new_commit}'],
                cwd=project_dir, stderr=subprocess.STDOUT
            ).decode().strip()
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(f'The "git log" command for project "{repo_path}" '
                               f'failed: {exc.stdout}') from exc

        get_commit_details = functools.partial(
            self.get_commit_details, repo_path=repo_path)

        old_commits = []
        if old_results:
            with concurrent.futures.ThreadPoolExecutor(max_workers=cpu_count()) as executor:
                old_commits = list(executor.map(
                    get_commit_details, old_results.split("\n")))

        try:
            new_results = self.check_output(
                missing + [f'{new_commit}...{old_commit}'],
                cwd=project_dir, stderr=subprocess.STDOUT
            ).decode().strip()
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(f'The "git log" command for project "{repo_path}" '
                               f'failed: {exc.stdout}') from exc

        new_commits = []
        if new_results:
            with concurrent.futures.ThreadPoolExecutor(max_workers=cpu_count()) as executor:
                new_commits = list(executor.map(
                    get_commit_details, new_results.split("\n")))

        project_name = self.get_project_name(repo_path)
        if project_name not in self.commits[self.product]:
            self.commits[self.product
                         ][project_name] = default_dict_factory()
            self.commits[self.product][project_name]["url"] = self.project_url(
                project_name)

        if new_commits:
            missing_commits = 0
            for commit in new_commits:
                new_sha, new_commit_message, new_author, _, _ = commit
                if any(
                    c.startswith(new_sha[:7]) for c in self.ignored_commits
                ):
                    continue

                backports = self.backports_of(get_tickets(new_commit_message))
                is_a_backport = False
                if backports:
                    gitlog = self.Popen(
                        ['git', 'log', '--oneline', new_commit],
                        cwd=project_dir,
                        stdout=subprocess.PIPE)
                    try:
                        matches = self.check_output(
                            ['grep', '-E'] + ['|'.join(backports)], stdin=gitlog.stdout
                        ).decode("ascii").strip().split("\n")
                        if len(matches) > 0:
                            is_a_backport = True
                    except subprocess.CalledProcessError as exc:
                        if exc.returncode == 1:
                            # grep most likely failed to find a match.
                            pass
                        else:
                            self.log.warning(f"Exception: {exc.output}")

                if is_a_backport:
                    self.matched_commits += 1
                    self.add_match("Backport", project_name, new_author, new_sha, new_commit_message, new_sha, new_commit_message, {"backports": {
                        match.split(" ")[0]: match.split(" ", 1)[1] for match in matches
                    }})
                    continue

                if (self.match_summary(project_name, commit, old_commits) or
                        self.match_date(project_name, commit, old_commits) or
                        self.match_diff(project_name, commit, old_commits)):
                    continue

                if new_sha not in self.commits[self.product][project_name]["Missing"]:
                    self.commits[self.product][project_name]["Missing"][new_sha] = {
                        "present_in": [self.old_manifest],
                        "missing_from": [self.new_manifest],
                        "author": new_author,
                        "message": new_commit_message,
                    }
                    self.total_missing_commits += 1
                else:
                    if self.old_manifest not in self.commits[self.product][project_name]["Missing"][new_sha]["present_in"]:
                        self.commits[self.product][project_name]["Missing"][new_sha]["present_in"].append(
                            self.old_manifest)
                    if self.new_manifest not in self.commits[self.product][project_name]["Missing"][new_sha]["missing_from"]:
                        self.commits[self.product][project_name]["Missing"][new_sha]["missing_from"].append(
                            self.new_manifest)
                missing_commits += 1
            self.log.info(
                f"Missing commits for {project_name}: {missing_commits}")

    def notify_users(self, recipient=None):
        """
        Collate a list of changes per project per user, and notify via slack
        """

        report = {}

        for product, product_info in self.commits.items():
            for project, commits in product_info.items():
                for missing_commit, missing_commit_info in commits.get('Missing', {}).items():
                    author = missing_commit_info['author']
                    message = missing_commit_info['message']
                    present_in = missing_commit_info['present_in']
                    missing_from = missing_commit_info['missing_from']

                    if author not in report:
                        report[author] = {}
                    if project not in report[author]:
                        report[author][project] = {}
                    if missing_commit not in report[author][project]:
                        report[author][project][missing_commit] = {
                            "message": message,
                            "present_in": present_in,
                            "missing_from": missing_from,
                        }

        for author in report:
            target_user = recipient if recipient else author
            message = message_template.format(author=author, product=product)
            for project in report[author]:
                message += f"\n  Project: {project}\n"
                for commit in report[author][project]:
                    present_links = ", ".join([f"<{self.manifest_repo.replace('ssh://git@', 'https://').rstrip('/')}/blob/{self.manifest_branch}/{manifest}|{manifest}>" for manifest in report[author][project][commit]["present_in"]])
                    missing_links = ", ".join([f"<{self.manifest_repo.replace('ssh://git@', 'https://').rstrip('/')}/blob/{self.manifest_branch}/{manifest}|{manifest}>" for manifest in report[author][project][commit]["missing_from"]])
                    message += f"    *{report[author][project][commit].get('message')}* (<{self.commits[product][project]['url']}/commit/{commit}|{commit}>)\n"
                    message += f"         present: {present_links}\n"
                    message += f"         missing: {missing_links}\n"

            if author.endswith("@couchbase.com"):
                if self.notify:
                    self.send_alert(target_user, message)
                else:
                    if target_user not in self.notified_users:
                        self.notified_users.append(target_user)
            else:
                if author not in self.skipped_users:
                    self.skipped_users.append(author)

        # Show info about which users were emailed, and which were skipped
        if self.skipped_users:
            self.log.info(
                f"Skipped the following users as they are not Couchbase employees: {', '.join(self.skipped_users)}")
        if self.notified_users:
            if self.notify:
                self.log.info(
                    f"Successfully notified the following users: {', '.join(self.notified_users)}")
            else:
                self.log.info(
                    f"Would have notified the following users: {', '.join(self.notified_users)} about {self.total_missing_commits} missing commits")

def main():
    """
    Parse the command line, initialize logging and key information,
    create manifest paths and perform the missing commits check
    """

    parser = argparse.ArgumentParser(
        description='Determine potential missing commits'
    )
    parser.add_argument('-d', '--debug', action='store_true',
                        help='Show additional information during run')
    parser.add_argument('-s', '--show_matches', action='store_true',
                        help='Show matched commits')
    parser.add_argument('-n', '--notify', action='store_true',
                        help='Send slack notifications for missing commits')
    parser.add_argument('-e', '--test_email',
                        help='Email address of user all slack messages should be sent to')
    parser.add_argument('-p', '--projects', dest='targeted_projects',
                        help='Specific project or projects (comma separated) to target - will process all if unspecified')
    parser.add_argument('--reporef_dir',
                        help='Path to repo mirror reference directory')
    parser.add_argument('--manifest_dir',
                        help='Path to product metadata directory')
    parser.add_argument('--first_manifest',
                        help='First manifest for comparison',
                        default=None)
    parser.add_argument('--last_manifest',
                        help='Last manifest for comparison',
                        default=None)
    parser.add_argument('--manifest_repo', help='Git URL to manifest repo')
    parser.add_argument('product', help='Product to check')
    args = parser.parse_args()

    # Set up logging
    logger = logging.getLogger(__name__)
    logger.setLevel(logging.DEBUG)

    ch = logging.StreamHandler()
    if not args.debug:
        ch.setLevel(logging.INFO)

    logger.addHandler(ch)

    # Setup file paths and search for missing commits
    manifest_dir = pathlib.Path(args.manifest_dir)
    reporef_dir = pathlib.Path(args.reporef_dir)

    commit_checker = MissingCommits(
        logger, args.product, manifest_dir, args.manifest_repo,
        reporef_dir, args.targeted_projects, args.debug, args.show_matches,
        args.notify
    )

    manifest_missing = False
    if args.first_manifest and args.first_manifest not in commit_checker.manifests:
        manifest_missing = True
        print(
            f"First manifest {args.first_manifest} not found in product-config.json for {args.product}")

    if args.last_manifest and args.last_manifest not in commit_checker.manifests:
        manifest_missing = True
        print(
            f"Last manifest {args.last_manifest} not found in product-config.json for {args.product}")

    if manifest_missing:
        sys.exit(1)

    capturing_manifests = True
    if args.first_manifest:
        capturing_manifests = False

    manifests = []
    for manifest in commit_checker.manifests:
        if args.first_manifest and not capturing_manifests:
            if manifest == args.first_manifest:
                capturing_manifests = True
        if not capturing_manifests:
            continue
        else:
            manifests.append(manifest)
        if args.last_manifest and manifest == args.last_manifest:
            break

    commit_checker.manifests = manifests

    for a, b in combinations(commit_checker.manifests, 2):
        try:
            commit_checker.identify_missing_commits(a, b)
        except Exception:
            traceback.print_exc()
            sys.exit(1)

    if commit_checker.matched_commits > 0:
        print(f"Matched {commit_checker.matched_commits} commits")

    if commit_checker.total_missing_commits > 0:
        commit_checker.notify_users(args.test_email)
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == '__main__':
    main()
