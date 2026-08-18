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
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

from collections import defaultdict
from itertools import combinations
from packaging.version import Version
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError
from thefuzz import fuzz
from time import sleep

from manifest_tools.scripts.jira_util import connect_jira, get_tickets


slack_oauth_token = os.getenv("SLACK_OAUTH_TOKEN")

message_header_template = """
Hi {author},

The commit checker has identified commits attributed to you - as their author, their committer, or the owner of the Gerrit change they were merged as - that appear to be missing in subsequent version(s) of {product}.

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

    # Pre-compiled regex for the Change-Id of a Gerrit-merged commit
    change_id_regex = re.compile(r'^Change-Id:\s*(I[0-9a-f]+)\s*$',
                                 re.MULTILINE)

    # Projects whose changes live somewhere other than Couchbase's Gerrit;
    # anything not listed here is looked up in GERRIT_HOST
    project_gerrit_hosts = {
        "asterixdb": "asterix-gerrit.ics.uci.edu",
    }

    # Pre-compiled regexes for backport substrings - we strip anything inside
    # [] as the format varies
    backport_regex = re.compile(r'\[.*?\][\s:]*')

    # After removing potential backport substrings, we strip out all non alpha
    # numeric characters to account for variances in punctuation, spaces etc.
    normalize_regex = re.compile(r'[^a-zA-Z0-9]')

    # Per-manifest options read from product-config.json.  A manifest which
    # is only in the list to have commits tracked into it - e.g. an
    # enterprise-analytics manifest listed under couchbase-server - wants all
    # three of these
    fmc_force = "find_missing_commits_force"
    fmc_target_only = "find_missing_commits_target_only"
    fmc_skip_inherited = "find_missing_commits_skip_inherited"
    fmc_options = (fmc_force, fmc_target_only, fmc_skip_inherited)

    # Matched commits are categorised, the order here dictates the order they
    # will be shown in when running with DEBUG=true
    match_types = ["Backport", "Date match", "Diff match", "Summary match"]

    # Fragments of repo's manifest_xml.py used by fix_diffmanifests_cmd()
    diffmanifests_except_from = \
        "                except ManifestInvalidRevisionError:"
    diffmanifests_except_to = \
        "                except (ManifestInvalidRevisionError, GitError):"
    diffmanifests_import_anchor = "from error import ManifestInvalidPathError"
    diffmanifests_import_added = "from error import GitError"

    def __init__(self, logger, product, manifest_dir, manifest_repo,
                 first_manifest, last_manifest, reporef_dir,
                 targeted_projects, debug, show_matches,
                 only_boundaries, compare_builds, notify):
        """
        Store key information into instance attributes and determine
        path of 'repo' program
        """

        self.log = logger
        self.debug = debug
        self.show_matches = show_matches
        self.only_boundaries = only_boundaries
        self.compare_builds = compare_builds
        self.notify = notify

        self.sha_lock = threading.Lock()
        self.date_lock = threading.Lock()
        self.gerrit_lock = threading.Lock()

        # Used to attribute commits whose author isn't a Couchbase address.
        # We query Gerrit's REST API anonymously, so this needs no
        # credentials but only sees changes in public projects
        self.gerrit_host = os.getenv("GERRIT_HOST")
        self.gerrit_warned = set()

        # Non-Couchbase author address -> the Couchbase address we managed to
        # attribute one of their commits to, so their other commits can be
        # attributed too, whatever order we come across them in
        self.resolved_authors = {}

        self.matched_commits = 0

        self.product = product
        self.product_dir = pathlib.Path(product)
        self.manifest_dir = manifest_dir
        self.manifest_repo = manifest_repo
        self.manifest_branch = "main" if product == "sync_gateway" else "master"
        self.reporef_dir = reporef_dir
        self.targeted_projects = [project.strip() for project in targeted_projects.split(",")] if targeted_projects else None

        self.first_manifest = first_manifest
        self.last_manifest = last_manifest

        self.commits = default_dict_factory()
        self.long_shas = {}
        self.commit_authors_and_dates = {}
        self.commit_committers = {}
        self.gerrit_owners = {}

        # Projects we don't care about
        self.ignore_projects = [
            'testrunner', 'libcouchbase', 'product-texts', 'product-metadata']

        self.git_bin = shutil.which('git')
        self.repo_bin = shutil.which('repo')

        self.slack_client = WebClient(token=slack_oauth_token)
        self.manifests = self.get_manifests(product, self.manifest_dir)

        self.notified_users = []
        self.skipped_users = []
        self.skipped_projects = []

        # We check jira and ignore tickets which are flagged "is a backport of"
        # a ticket in the newer release
        try:
            self.log.debug("Connecting to Jira")
            self.jira = connect_jira()
        except Exception as exc:
            traceback.print_exc()
            self.log.critical("Jira connection failed")
            raise RuntimeError("Jira connection failed") from exc

    @property
    def total_missing(self):
        """
        Return the total number of missing commits
        """
        total = 0
        for project, info in self.commits[self.product].items():
            commits = info.get("TrackedCommits", {})
            total += sum(1 for sha, match_details in commits.items() if match_details['missing_from'])
        return total

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

        if self.total_missing > 0:
            output += header("MISSING COMMITS", self.total_missing)
            for project, info in self.commits[self.product].items():
                commits = {sha: details for sha, details in info.get("TrackedCommits", {}).items() if details['missing_from']}
                if commits:
                    output += f"{os.linesep}Project {project} - missing: {len(commits)}{os.linesep}"
                    for sha, match_details in commits.items():
                        # Show the missing commit info, along with the branches/releases it is missing from
                        output += f"    [{sha[:7]}] {match_details['message']}{os.linesep}             Date: {match_details['date']}{os.linesep}       Present in: {', '.join(match_details['present_in'])}{os.linesep}     Missing from: {', '.join(match_details['missing_from'])}{os.linesep}"
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

    def fix_diffmanifests_cmd(self):
        """
        'repo diffmanifests' collects projects whose revision it can't
        resolve into an 'unreachable' bucket and carries on, but it only
        catches ManifestInvalidRevisionError.  A project which moved to a
        different remote between the two manifests raises GitError from
        Remote.ToLocal instead - the project's git config has no section for
        the remote the older manifest names it on - and that escapes the
        handler, aborting the entire command and losing every other project
        in the comparison with it.  Widen the except clause so such projects
        are reported as unreachable like any other.
        """
        file_path = self.product_dir / ".repo/repo/manifest_xml.py"
        warning = (f"Unable to patch {file_path}, 'repo diffmanifests' will "
                   f"abort rather than skip projects which changed remote")

        try:
            content = file_path.read_text()
        except OSError as exc:
            self.log.warning(f"{warning}: {exc}")
            return

        if self.diffmanifests_except_to in content:
            return   # Already patched

        if (self.diffmanifests_except_from not in content
                or self.diffmanifests_import_anchor not in content):
            self.log.warning(warning)
            return

        content = content.replace(self.diffmanifests_except_from,
                                  self.diffmanifests_except_to)
        content = content.replace(
            self.diffmanifests_import_anchor,
            f"{self.diffmanifests_import_added}\n"
            f"{self.diffmanifests_import_anchor}")

        file_path.write_text(content)
        self.log.debug(f"Patched {file_path}")

    def send_alert(self, email, header, body):
        try:
            user = self.slack_client.users_lookupByEmail(email=email)['user']['id']
            channel = self.slack_client.conversations_open(users=user)['channel']['id']
            self.slack_client.chat_postMessage(
                channel=channel,
                text=header+body
            )
            if email not in self.notified_users:
                self.notified_users.append(email)
        except SlackApiError as e:
            self.log.error(f"Error: {e.response['error']}")
            self.log.error(f"Notification for {email} could not be delivered: {body}")

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

    def get_manifest_annotation(self, manifest, annotation_name):
        tree = ET.parse(self.manifest_dir / manifest)
        root = tree.getroot()
        build = root.find("project[@name='build']")
        if build:
            for annotation in build.findall("annotation"):
                if annotation.get("name") == annotation_name:
                    return annotation.get("value")

    def manifest_option(self, manifest, option):
        """
        Read one of the per-manifest 'find_missing_commits_*' options from
        product-config.json
        """

        return bool(self.manifest_config.get(manifest, {}).get(option, False))

    def manifest_project_paths(self, manifest):
        """
        Return the repo paths of the projects a manifest configures itself,
        via <project> or <extend-project>, ignoring anything it only picks up
        through an <include>.

        A product whose manifest includes another product's - e.g.
        enterprise-analytics, which builds on couchbase-server - owns only
        the projects it names, and the rest are covered by the check for the
        product they come from.

        <include> is deliberately not followed.  The paths come from the
        manifest 'repo manifest -r' produced during the sync, which is where
        a project's path is resolved (and defaults to its name).
        """

        if os.path.isabs(manifest):
            manifest_path = manifest
        else:
            manifest_path = self.product_dir / ".repo/manifests" / manifest

        try:
            root = ET.parse(manifest_path).getroot()
        except (ET.ParseError, OSError) as exc:
            self.log.warning(f'Unable to read {manifest_path} to work out '
                             f'which projects it configures: {exc}')
            return None

        names = {
            project.get("name")
            for element in ("project", "extend-project")
            for project in root.findall(element)
            if project.get("name")
        }

        paths = set()
        resolved = ET.parse(pathlib.Path('new.xml').resolve()).getroot()
        for project in resolved.findall("project"):
            if project.get("name") in names:
                paths.add(project.get("path") or project.get("name"))

        missing = names - {
            project.get("name") for project in resolved.findall("project")}
        if missing:
            # Projects the manifest removes again, or which aren't in the
            # groups we synced, simply aren't ours to check
            self.log.debug(f'{manifest} names projects which aren\'t in the '
                           f'checkout, ignoring: {", ".join(sorted(missing))}')

        return paths

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
                        default_version = Version(
                            self.get_manifest_annotation(manifest_dir / "manifest/default.xml", "VERSION"))
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
            self.manifest_config = data["manifests"]

            # Nothing validates product-config.json, so a mistyped option
            # would otherwise be silently ignored
            for manifest, config in self.manifest_config.items():
                for key in config:
                    if (key.startswith("find_missing_commits")
                            and key not in self.fmc_options):
                        self.log.warning(
                            f"Unrecognised option '{key}' for {manifest} in "
                            f"{product_config}, ignoring it - the options are "
                            f"{', '.join(self.fmc_options)}")
            if product == "sync_gateway":
                raw_manifest_list = list(data["manifests"].keys())[::-1]
            else:
                raw_manifest_list = list(data["manifests"].keys())

            for manifest in raw_manifest_list:
                manifest_config = data["manifests"][manifest]
                # 'do-build' says whether a manifest is still built, which
                # isn't the same question as whether we still want commits
                # tracked from it - a release train can stop being built long
                # before the commits on it have all been merged forward - so
                # let a manifest opt back in to the check on its own
                if (manifest_config.get("do-build", True)
                        or self.manifest_option(manifest, self.fmc_force)):
                    manifests.append(manifest)

        active_manifests = []

        for node_name in manifests:
            # Define conditions for skipping a manifest
            is_couchbase_server = product == "couchbase-server"
            has_digit_in_name = any(char.isdigit() for char in node_name)
            not_comparing_builds = not self.compare_builds
            not_boundary_manifest = node_name not in [self.first_manifest, self.last_manifest]

            # Skip manifests with version numbers (containing digits) for couchbase-server,
            # except when they're explicitly specified as first/last manifest
            # or when we're directly comparing two specific builds
            should_skip = (is_couchbase_server and
                          has_digit_in_name and
                          not_comparing_builds and
                          not_boundary_manifest)

            if should_skip:
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

        # Use the manifest 'repo manifest -r' produced during the sync rather
        # than the manifest we were given.  repo has already expanded any
        # <include> elements and folded <extend-project> overrides into the
        # projects they extend, so we don't have to reimplement any of that
        # here.  Manifests which pull their projects in via <include> and then
        # override them via <extend-project> - e.g. enterprise-analytics,
        # which includes couchbase-server - have no <project> element of their
        # own to find otherwise.
        manifest_path = pathlib.Path('new.xml').resolve()

        tree = ET.parse(manifest_path)
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

        # When the target manifest asks for it, restrict the comparison to
        # the projects it configures itself - what it inherits through an
        # <include> is the business of the product it came from
        scope = None
        if self.manifest_option(self.new_manifest, self.fmc_skip_inherited):
            scope = self.manifest_project_paths(self.new_manifest)
            if scope is not None:
                self.log.info(
                    f"{self.new_manifest} configures {len(scope)} projects "
                    f"directly, limiting the comparison to those")

        # Perform commit diffs, handling merged projects by diffing
        # the merged project against each of the projects the were
        # merged into it
        for repo_path, change_info in changes.items():
            if scope is not None and repo_path not in scope:
                continue
            if self.targeted_projects and repo_path.split("/")[-1] not in self.targeted_projects:
                continue
            # A project we can't diff - e.g. one holding a revision which
            # isn't in the checkout, because it came from a remote the newer
            # manifest doesn't use - shouldn't cost us every other project in
            # the comparison, so note it and carry on
            try:
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
            except Exception as exc:
                self.log.warning(
                    f'Project {repo_path} was not compared between '
                    f'{self.old_manifest} and {self.new_manifest}: {exc}')
                self.skipped_projects.append(
                    (self.old_manifest, self.new_manifest, repo_path, exc))

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
                   self.manifest_dir,
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
                    f'--jobs=8', '--force-sync']
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

        # Patch last - 'repo sync' can update .repo/repo, which would undo
        # anything we'd applied before it
        self.fix_diffmanifests_cmd()

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

        project_lines = [
            line for line in diffs.strip().split('\n')
            if not line.startswith(' ')
        ]

        # Projects repo couldn't resolve a revision for are reported as
        # unreachable and are not compared - say so, rather than leaving a
        # silent hole in the results
        for line in project_lines:
            if line.startswith('U '):
                _, repo_path, old_rev, new_rev = line.split()
                self.log.warning(
                    f'Project {repo_path} was not compared, repo could not '
                    f'resolve {old_rev} in {self.old_manifest} and/or '
                    f'{new_rev} in {self.new_manifest}')

        return project_lines

    def get_author_and_dates(self, repo_path, commit_sha):
        """
        Get the author date for a specific SHA
        """

        with self.date_lock:
            if commit_sha in self.commit_authors_and_dates:
                return self.commit_authors_and_dates[commit_sha]

        project_dir = self.product_dir / repo_path
        try:
            # The committer comes along for free here, and is needed when the
            # author turns out not to be a Couchbase address
            (author, committer, author_date, commit_date) = self.check_output(
                ['git', 'show', '-s', '--format=%ae|%ce|%ai|%ci', commit_sha],
                cwd=project_dir
            ).decode().strip().split("|")
            self.commit_authors_and_dates[commit_sha] = (author, author_date, commit_date)
            self.commit_committers[commit_sha] = committer
            return (author, author_date, commit_date)
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(
                f'Failed to retrieve author and commit dates for '
                f'{commit_sha}: {exc.output}') from exc

    @staticmethod
    def is_couchbase_email(email):
        return bool(email) and email.endswith("@couchbase.com")

    def gerrit_change_owner(self, repo_path, commit_sha):
        """
        Find the Gerrit owner of the change a commit was merged as, via the
        Change-Id in its commit message.

        The query is anonymous, so only changes in public projects resolve -
        one in a restricted project simply doesn't, until we have credentials
        to query with.  That's still enough for a contributor who has any
        public change, as the address it turns up is reused for the rest of
        their commits.

        Returns None if the commit didn't come through Gerrit, if the change
        isn't visible, or if Gerrit can't be reached - this is a fallback for
        attributing commits, not something worth failing over.
        """

        host = self.project_gerrit_hosts.get(
            repo_path.split('/')[-1], self.gerrit_host)
        if not host:
            return None

        with self.gerrit_lock:
            if commit_sha in self.gerrit_owners:
                return self.gerrit_owners[commit_sha]

        owner = None
        try:
            message = self.check_output(
                ['git', 'show', '-s', '--format=%B', commit_sha],
                cwd=self.product_dir / repo_path
            ).decode(errors='replace')
            change_id = self.change_id_regex.search(message)
            if not change_id:
                self.log.debug(f'{commit_sha[:7]} has no Change-Id, it did '
                               f'not come through Gerrit')
            else:
                query = urllib.parse.urlencode(
                    {'q': f'change:{change_id.group(1)}',
                     'o': 'DETAILED_ACCOUNTS'})
                with urllib.request.urlopen(
                        f'https://{host}/changes/?{query}',
                        timeout=30) as response:
                    body = response.read().decode(errors='replace')
                # Gerrit prefixes its JSON with )]}' to defeat cross site
                # script inclusion
                if body.startswith(")]}'"):
                    body = body[4:]
                for change in json.loads(body):
                    owner = change.get('owner', {}).get('email')
                    if owner:
                        break
                if not owner:
                    self.log.debug(
                        f'{host} has no visible change '
                        f'{change_id.group(1)} for {commit_sha[:7]}')
        except (subprocess.CalledProcessError, json.JSONDecodeError,
                OSError, ValueError) as exc:
            # Warn once per host rather than per commit - a Gerrit we can't
            # reach fails the same way every time, and silently losing the
            # fallback is how this went unnoticed before
            if host not in self.gerrit_warned:
                self.gerrit_warned.add(host)
                self.log.warning(
                    f'Unable to query Gerrit at {host}, commits from '
                    f'non-Couchbase addresses will not be attributed via '
                    f'their Gerrit change: {exc}')
            self.log.debug(
                f'Unable to determine the Gerrit owner of {commit_sha}: {exc}')

        with self.gerrit_lock:
            self.gerrit_owners[commit_sha] = owner
        return owner

    def notify_email(self, repo_path, commit_sha, author):
        """
        Work out who to tell about a missing commit.  Commits authored from a
        non-Couchbase address - external contributors, personal addresses -
        would otherwise go unreported, so fall back to whoever committed it,
        and failing that to the owner of the Gerrit change it was merged as.
        Returns the author unchanged if nothing better can be found, leaving
        the caller to skip it as before.
        """

        if self.is_couchbase_email(author):
            return author

        committer = self.commit_committers.get(commit_sha)
        if self.is_couchbase_email(committer):
            self.log.debug(f'Attributing {commit_sha[:7]} to its committer '
                           f'{committer}, author {author} is not a Couchbase '
                           f'address')
            return committer

        known = self.resolved_authors.get(author)
        if known:
            self.log.debug(f'Attributing {commit_sha[:7]} to {known}, already '
                           f'resolved for author {author}')
            return known

        owner = self.gerrit_change_owner(repo_path, commit_sha)
        if self.is_couchbase_email(owner):
            self.log.info(f'Attributing commits authored by {author} to '
                          f'{owner}, the owner of the Gerrit change '
                          f'{commit_sha[:7]} was merged as')
            self.resolved_authors[author] = owner
            return owner

        return author

    def get_commit_details(self, line, repo_path):
        """
        Retrieves the commit details for a given line of git output
        (a sha followed by the subject line of that sha)
        """
        sha, msg = line.split(' ', 1)
        long_sha = self.get_long_sha(repo_path, sha)
        author, author_date, commit_date = self.get_author_and_dates(repo_path, long_sha)
        diff_changes = self.get_diff_changes(repo_path, long_sha)
        return (sha, msg, author, author_date, commit_date, diff_changes)

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

    def _mark_commit_status(self, project, sha, present_in=None, missing_from=None):
        """
        Update the presence/absence status of a commit across manifests.
        """
        status = self.commits[self.product][project]["TrackedCommits"][sha]

        if present_in:
            for manifest in present_in:
                if manifest not in status["present_in"]:
                    status["present_in"].append(manifest)
                if manifest in status["missing_from"]:
                    status["missing_from"].remove(manifest)

        if missing_from:
            for manifest in missing_from:
                if manifest not in status["present_in"] and manifest not in status["missing_from"]:
                    status["missing_from"].append(manifest)

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

        # If this commit was previously suspected to be missing, we now have evidence
        # that it is present in both manifests (e.g., via a backport or fuzzy match).
        tracked = self.commits[self.product][project].get("TrackedCommits", {})
        if new_sha in tracked:
            self._mark_commit_status(project, new_sha, present_in=[self.old_manifest, self.new_manifest])

        self.matched_commits += 1

    def match_date(self, project, new_commit, old_commits):
        """
        Checks if the date of a new commit matches the date of any old commit
        in a list of old commits.
        """

        new_sha, new_commit_message, new_author, new_author_date, _, _ = new_commit
        for old_sha, old_commit_message, old_author, old_author_date, _, _ in old_commits:
            if old_author_date == new_author_date and old_author == new_author:
                self.add_match("Date match", project, old_author, old_sha,
                               old_commit_message, new_sha, new_commit_message)
                return True

    def match_diff(self, project, new_commit, old_commits):
        """
        Fuzzy comparison of two diffs (changes only)
        """

        new_sha, new_commit_message, _, _, _, new_diff = new_commit
        for old_sha, old_commit_message, old_author, _, _, old_diff in old_commits:
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
        new_sha, new_commit_message, _, _, _, _ = new_commit
        for old_sha, old_commit_message, old_author, _, _, _ in old_commits:
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
        release = None

        # Find the release we're working with
        if self.product == "sync_gateway":
            release = ".".join(os.path.basename(self.new_manifest).split('.')[:-1])
        elif self.new_manifest.endswith("branch-master.xml"):
            release = "master"
        else:
            release = self.get_manifest_annotation(self.new_manifest, "RELEASE")
            manifest_parts = self.new_manifest.split('/')
            if not release:
                if len(manifest_parts) == 3: # e.g. couchbase-server/trinity/7.6.5.xml
                    release = manifest_parts[-2]
                elif len(manifest_parts) == 2:  # e.g. couchbase-server/trinity.xml
                    release = manifest_parts[-1].split('.')[0]

        if not release:
            self.log.warning(f'Unable to determine release for manifest '
                             f'{self.new_manifest}, no ignored commits will be '
                             f'applied.  Continuing...')
            return commits

        try:
            self.log.info(f"Missing commit file is /data/metadata/product-metadata/{self.product}/missing_commits/{release}/ok-missing-commits.txt")
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
        Determine missing commits for a given project based on two commit
        SHAs for the project. This is done by doing a 'git log' on the
        symmetric difference of the two commits in forward and reversed order,
        then comparing the summary content, dates and diffs from the latter to
        find a matching entry in the former, which are all strong indications
        that the commit was properly merged into the project at the time of the
        target manifest.
        Retrieve any possible matches along with any missing commits to
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

        source_sha, target_sha = change_info
        missing_cmd_base = [
            self.git_bin, 'log', '--oneline', '--cherry-pick',
            '--right-only', '--no-merges'
        ]

        source_sha = self.get_long_sha(repo_path, source_sha)
        target_sha = self.get_long_sha(repo_path, target_sha)

        project_dir = self.product_dir / repo_path

        # Commits that are in the target manifest but NOT in the source manifest
        try:
            target_only_results = self.check_output(
                missing_cmd_base + [f'{source_sha}...{target_sha}'],
                cwd=project_dir, stderr=subprocess.STDOUT
            ).decode().strip()
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(f'The "git log" command for project "{repo_path}" '
                               f'failed: {exc.stdout}') from exc

        get_commit_details = functools.partial(
            self.get_commit_details, repo_path=repo_path)

        target_only_commits = []
        if target_only_results:
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                target_only_commits = list(executor.map(
                    get_commit_details, target_only_results.split("\n")))

        # Commits that are in the source manifest but NOT in the target manifest
        # (These are the potentially missing commits we're checking for)
        try:
            source_only_results = self.check_output(
                missing_cmd_base + [f'{target_sha}...{source_sha}'],
                cwd=project_dir, stderr=subprocess.STDOUT
            ).decode().strip()
        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(f'The "git log" command for project "{repo_path}" '
                               f'failed: {exc.stdout}') from exc

        source_only_commits = []
        if source_only_results:
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                source_only_commits = list(executor.map(
                    get_commit_details, source_only_results.split("\n")))

        project_name = self.get_project_name(repo_path)
        if project_name not in self.commits[self.product]:
            self.commits[self.product
                         ][project_name] = default_dict_factory()
            self.commits[self.product][project_name]["url"] = self.project_url(
                project_name)

        if source_only_commits:
            missing_commits_count = 0
            for commit in source_only_commits:
                sha, message, author, _, commit_date, _ = commit

                if any(
                    c.startswith(sha[:7]) for c in self.ignored_commits
                ):
                    # Still update present_in to maintain cross-pair state.
                    # This pair proves the commit is present in old_manifest,
                    # which may resolve a missing_from entry left by an
                    # earlier pair that couldn't detect the cherry-pick
                    if sha in self.commits[self.product][project_name]["TrackedCommits"]:
                        self._mark_commit_status(project_name, sha, present_in=[self.old_manifest])
                    continue

                backports = self.backports_of(get_tickets(message))
                is_a_backport = False
                if backports:
                    gitlog = self.Popen(
                        ['git', 'log', '--oneline', target_sha],
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
                    self.add_match("Backport", project_name, author, sha, message, sha, message, {"backports": {
                        match.split(" ")[0]: match.split(" ", 1)[1] for match in matches
                    }})
                    continue

                if (self.match_summary(project_name, commit, target_only_commits) or
                        self.match_date(project_name, commit, target_only_commits) or
                        self.match_diff(project_name, commit, target_only_commits)):
                    continue

                if sha not in self.commits[self.product][project_name]["TrackedCommits"]:
                    # Resolve who to notify now, while the checkout this
                    # commit came from is still around - repo_sync() replaces
                    # it for every manifest pair, so by the time we come to
                    # notify it may well be gone
                    self.commits[self.product][project_name]["TrackedCommits"][sha] = {
                        "present_in": [],
                        "missing_from": [],
                        "author": author,
                        "notify": self.notify_email(
                            repo_path, self.get_long_sha(repo_path, sha),
                            author),
                        "message": message,
                        "date": commit_date,
                    }

                self._mark_commit_status(project_name, sha,
                                        present_in=[self.old_manifest],
                                        missing_from=[self.new_manifest])
                missing_commits_count += 1
            self.log.info(
                f"Missing commits for {project_name}: {missing_commits_count}")

    def notify_users(self, recipient=None):
        """
        Collate a list of changes per project per user, and notify via slack
        """

        report = {}

        for product, product_info in self.commits.items():
            for project, commits in product_info.items():
                for missing_commit, missing_commit_info in commits.get('TrackedCommits', {}).items():
                    author = missing_commit_info['author']
                    # Commits authored from a non-Couchbase address are
                    # attributed to their committer, or to the owner of the
                    # Gerrit change they were merged as
                    target = missing_commit_info.get('notify') or author
                    if not self.is_couchbase_email(target):
                        # We may have worked out who this author is since,
                        # from another of their commits - e.g. one that went
                        # through Gerrit where this one didn't
                        target = self.resolved_authors.get(author, target)
                    message = missing_commit_info['message']
                    present_in = missing_commit_info['present_in']
                    missing_from = missing_commit_info['missing_from']

                    if not missing_from:
                        continue

                    if target not in report:
                        report[target] = {}
                    if project not in report[target]:
                        report[target][project] = {}
                    if missing_commit not in report[target][project]:
                        report[target][project][missing_commit] = {
                            "message": message,
                            "present_in": present_in,
                            "missing_from": missing_from,
                            "author": author,
                        }

        for target in report:
            target_user = recipient if recipient else target
            message_header = message_header_template.format(author=target, product=product)
            message = ""
            for project in report[target]:
                message += f"\n  Project: {project}\n"
                for commit in report[target][project]:
                    present_links = ", ".join([f"<{self.manifest_repo.replace('ssh://git@', 'https://').rstrip('/')}/blob/{self.manifest_branch}/{manifest}|{manifest}>" for manifest in report[target][project][commit]["present_in"]])
                    missing_links = ", ".join([f"<{self.manifest_repo.replace('ssh://git@', 'https://').rstrip('/')}/blob/{self.manifest_branch}/{manifest}|{manifest}>" for manifest in report[target][project][commit]["missing_from"]])
                    message += f"    *{report[target][project][commit].get('message')}* (<{self.commits[product][project]['url']}/commit/{commit}|{commit}>)\n"
                    message += f"         date: {self.commits[product][project]['TrackedCommits'][commit]['date']}\n"
                    # Say whose commit it is when we're not telling the author
                    author = report[target][project][commit]["author"]
                    if author != target:
                        message += f"         author: {author}\n"
                    message += f"         present: {present_links}\n"
                    message += f"         missing: {missing_links}\n"

            if self.is_couchbase_email(target):
                if self.notify:
                    self.send_alert(target_user, message_header, message)
                else:
                    if target_user not in self.notified_users:
                        self.notified_users.append(target_user)
            else:
                if target not in self.skipped_users:
                    self.skipped_users.append(target)

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
                    f"Would have notified the following users: {', '.join(self.notified_users)} about {self.total_missing} missing commits")


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
    parser.add_argument('--only_boundaries', action='store_true',
                        help='Only check commits at manifest boundaries')
    parser.add_argument('--compare_builds', action='store_true', default=False,
                        help='Compare two specific builds')
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
        args.first_manifest, args.last_manifest,
        reporef_dir, args.targeted_projects, args.debug,
        args.show_matches, args.only_boundaries,
        args.compare_builds, args.notify
    )

    manifest_missing = False
    if not args.compare_builds and args.first_manifest and args.first_manifest not in commit_checker.manifests:
        manifest_missing = True
        print(
            f"First manifest {args.first_manifest} not found in product-config.json for {args.product}")

    if not args.compare_builds and args.last_manifest and args.last_manifest not in commit_checker.manifests:
        manifest_missing = True
        print(
            f"Last manifest {args.last_manifest} not found in product-config.json for {args.product}")

    if manifest_missing:
        sys.exit(1)

    manifests = []

    if args.only_boundaries:
        manifests = [args.first_manifest, args.last_manifest]
    else:
        if args.first_manifest:
            if args.first_manifest not in commit_checker.manifests:
                print(f"First manifest {args.first_manifest} not found in active manifests")
                sys.exit(1)
            if args.last_manifest and args.last_manifest not in commit_checker.manifests:
                print(f"Last manifest {args.last_manifest} not found in active manifests")
                sys.exit(1)

            first_idx = commit_checker.manifests.index(args.first_manifest)
            last_idx = commit_checker.manifests.index(args.last_manifest) if args.last_manifest else len(commit_checker.manifests) - 1

            if first_idx > last_idx:
                first_idx, last_idx = last_idx, first_idx

            manifests = commit_checker.manifests[first_idx:last_idx + 1]
        elif args.last_manifest:
            last_idx = commit_checker.manifests.index(args.last_manifest)
            manifests = commit_checker.manifests[:last_idx + 1]
        else:
            manifests = commit_checker.manifests

    commit_checker.manifests = manifests

    # A comparison can fail for reasons outside our control - e.g. a project
    # which moved to a different remote between the two manifests, leaving
    # 'repo diffmanifests' unable to resolve the older manifest's revision
    # against the checkout we synced from the newer one.  Carry on with the
    # remaining manifests rather than losing the whole run to one bad pair,
    # and report the failures at the end.
    failed_comparisons = []

    # A manifest with find_missing_commits_target_only set is never compared
    # as the source of a pair; it is in the list to have commits tracked into
    # it, not out of it, so it can't end up being checked the other way round
    # purely because of where it sits in product-config.json
    comparisons = []
    for a, b in combinations(commit_checker.manifests, 2):
        if commit_checker.manifest_option(
                a, commit_checker.fmc_target_only):
            logger.debug(f"Not comparing {a} against {b}, {a} only has "
                         f"commits tracked into it")
            continue
        comparisons.append((a, b))

    for a, b in comparisons:
        try:
            commit_checker.identify_missing_commits(a, b)
        except Exception as exc:
            traceback.print_exc()
            logger.error(
                f"Comparison of {a} and {b} failed, continuing with the "
                f"remaining manifests")
            failed_comparisons.append((a, b, exc))

    if commit_checker.matched_commits > 0:
        print(f"Matched {commit_checker.matched_commits} commits")

    print(commit_checker)

    if commit_checker.skipped_projects:
        print(f"{os.linesep}PROJECTS NOT COMPARED: "
              f"{len(commit_checker.skipped_projects)}")
        for a, b, repo_path, exc in commit_checker.skipped_projects:
            print(f"    {repo_path} ({a} -> {b}){os.linesep}        {exc}")

    if failed_comparisons:
        print(f"{os.linesep}FAILED COMPARISONS: {len(failed_comparisons)}")
        for a, b, exc in failed_comparisons:
            print(f"    {a} -> {b}{os.linesep}        {exc}")

    if commit_checker.total_missing > 0:
        commit_checker.notify_users(args.test_email)

    # A project or comparison we couldn't check is a hole in the results, not
    # a clean run, so don't report success for it
    if (commit_checker.total_missing > 0 or failed_comparisons
            or commit_checker.skipped_projects):
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == '__main__':
    main()
