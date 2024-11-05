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
import re
import shutil
import subprocess
import sys
import threading
import traceback

from collections import defaultdict
from thefuzz import fuzz
from time import sleep

from manifest_tools.scripts.jira_util import connect_jira, get_tickets


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

    # Pre-compiled regexes for backport substrings - we strip anything inside
    # [] as the format varies
    backport_regex = re.compile(r'\[.*?\][\s:]*')

    # After removing potential backport substrings, we strip out all non alpha
    # numeric characters to account for variances in punctuation, spaces etc.
    normalize_regex = re.compile(r'[^a-zA-Z0-9]')

    # Matched commits are categorised, the order here dictates the order they
    # will be shown in when running with DEBUG=true
    match_types = ["Backport", "Date match", "Diff match", "Summary match"]

    def __init__(self, logger, product_dir, old_manifest, new_manifest,
                 manifest_repo, reporef_dir, ignored_commits,
                 pre_merge, post_merge, merge_map, targeted_project, debug):
        """
        Store key information into instance attributes and determine
        path of 'repo' program
        """

        self.debug = debug
        self.log = logger

        self.sha_lock = threading.Lock()
        self.date_lock = threading.Lock()

        self.missing_commits = 0
        self.matched_commits = 0

        self.product_dir = product_dir
        self.old_manifest = old_manifest
        self.new_manifest = new_manifest
        self.manifest_repo = manifest_repo
        self.reporef_dir = reporef_dir
        self.ignored_commits = ignored_commits
        self.pre_merge = pre_merge
        self.post_merge = post_merge
        self.merge_map = merge_map
        self.targeted_project = targeted_project

        self.commits = default_dict_factory()
        self.long_shas = {}
        self.commit_dates = {}

        # Projects we don't care about
        self.ignore_projects = [
            'testrunner', 'libcouchbase', 'product-texts', 'product-metadata']

        self.git_bin = shutil.which('git')
        self.repo_bin = shutil.which('repo')

        # We check jira and ignore tickets which are flagged "is a backport of"
        # a ticket in the newer release
        try:
            self.jira = connect_jira()
        except Exception as exc:
            traceback.print_exc()
            self.log.critical("Jira connection failed")
            raise RuntimeError("Jira connection failed") from exc
        self()

    def __call__(self):
        """
        Identifies and outputs missing commits

        This method performs the following steps:
        1. Syncs the manifest
        2. Calculates the difference between manifests
        3. Creates a dictionary of relevant changes, including added, removed,
           and changed projects
        4. Performs commit diffs for merged projects
        5. Prints the result
        """

        self.repo_sync()
        manifest_diff = self.diff_manifests()
        changes = dict()

        # Create dictionary with all the relevant changes; this avoids
        # any added or removed projects that were not part of a merge
        # process at some point in the past
        for entry in manifest_diff:
            if entry.startswith('A '):
                _, repo_path, current_commit = entry.split()
                if repo_path in self.post_merge:
                    changes[repo_path] = ('added', current_commit)
            elif entry.startswith('R '):
                _, repo_path, final_commit = entry.split()
                if repo_path in self.pre_merge:
                    changes[repo_path] = ('removed', final_commit)
            elif entry.startswith('C '):
                _, repo_path, old_commit, new_commit = entry.split()
                changes[repo_path] = ('changed', old_commit, new_commit)
            else:
                self.log.warning(f'Unhandled entry, skipping: {entry}')

        # Perform commit diffs, handling merged projects by diffing
        # the merged project against each of the projects the were
        # merged into it
        for repo_path, change_info in changes.items():
            if self.targeted_project and repo_path.split("/")[-1] != self.targeted_project:
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

        if self.missing_commits > 0:
            output += header("MISSING COMMITS", self.missing_commits)
            for project, info in self.commits[str(self.product_dir)][str(self.new_manifest)].items():
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

        if self.matched_commits > 0 and self.debug:
            output += header("MATCHES", self.matched_commits)
            for project, info in self.commits[str(self.product_dir)][str(self.new_manifest)].items():
                if any(info.get(match_type) for match_type in self.match_types):
                    output += f"{os.linesep}Project {project}:{os.linesep}"

                for match_type in self.match_types:
                    matches = info.get(match_type, {})
                    if matches:
                        padding = len(max(self.match_types, key=len)) - len(match_type)
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
                    jira_ticket = self.jira.issue(ticket)
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
                    traceback.print_exc()
                    raise RuntimeError(
                        f"Jira ticket retrieval failed for {ticket}") from exc
            else:
                # If we got here, we ran out of retries without hitting the
                # break
                raise RuntimeError(
                    f"Jira ticket retrieval failed for {ticket}")

        return backports

    def repo_sync(self):
        """
        Initialize and sync a repo checkout based on the target
        manifest; generate a new manifest with fixed SHAs in case
        the target contains branches (e.g. master) via the command
        'repo manifest -r' so 'git log' will work properly
        """

        # Create a 'product' directory to contain the repo checkout
        if self.product_dir.exists() and not self.product_dir.is_dir():
            self.log.warning(f'"{self.product_dir}" exists and is not a '
                             'directory, removing...')
            try:
                self.product_dir.unlink()
            except OSError as exc:
                traceback.print_exc()
                raise RuntimeError(
                    f'Unable to delete "{self.product_dir}" file/link: '
                    f'{exc.message}'
                ) from exc

        if not self.product_dir.exists():
            try:
                self.product_dir.mkdir()
            except OSError as exc:
                traceback.print_exc()
                raise RuntimeError(
                    f'Unable to create "{self.product_dir}" directory: '
                    f'{exc.message}'
                ) from exc

        try:
            cmd = [self.repo_bin, 'init', '-u',
                   self.manifest_repo,
                   '-g', 'all', '-m', self.new_manifest]
            if self.reporef_dir is not None:
                cmd.extend(['--reference', self.reporef_dir])
            subprocess.check_output(
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
            subprocess.check_output(
                [self.repo_bin, 'sync', '--jobs=6', '--force-sync'],
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
                subprocess.check_call(
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
            diffs = subprocess.check_output(
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

    def get_author_date(self, repo_path, commit_sha):
        """
        Get the author date for a specific SHA
        """

        with self.date_lock:
            if commit_sha in self.commit_dates:
                return self.commit_dates[commit_sha]

        project_dir = self.product_dir / repo_path
        try:
            date = subprocess.check_output(
                ['git', 'show', '-s', '--format=%ai', commit_sha],
                cwd=project_dir
            ).decode().strip()
            self.commit_dates[commit_sha] = date
            return date
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
        date = self.get_author_date(repo_path, long_sha)
        diff_changes = self.get_diff_changes(repo_path, long_sha)
        return (sha, msg, date, diff_changes)

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
            commit_sha = subprocess.check_output(
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
        project_name = subprocess.check_output(
            [self.repo_bin, 'forall', project_dir, '-c',
                f'echo $REPO_PROJECT'],
            cwd=self.product_dir, stderr=subprocess.STDOUT
        ).decode().strip()
        return project_name

    def match_date(self, project, new_commit, old_commits):
        """
        Checks if the date of a new commit matches the date of any old commit
        in a list of old commits.
        """

        new_sha, new_commit_message, new_date, _ = new_commit
        for old_sha, old_commit_message, old_date, _ in old_commits:
            if old_date == new_date:
                self.matched_commits += 1
                self.commits[str(self.product_dir)][str(self.new_manifest)][project]["Date match"][new_sha] = {
                    "message": new_commit_message,
                    "matched": {
                        old_sha: old_commit_message,
                    }
                }
                return True

    def match_diff(self, project, new_commit, old_commits):
        """
        Fuzzy comparison of two diffs (changes only)
        """

        new_sha, new_commit_message, _, new_diff = new_commit
        for old_sha, old_commit_message, _, old_diff in old_commits:
            if len(new_diff) <= 10:
                threshold = 90
            elif len(new_diff) <= 50:
                threshold = 80
            else:
                threshold = 70
            ratio = fuzz.ratio(new_diff, old_diff)
            if ratio > threshold:
                self.matched_commits += 1
                self.commits[str(self.product_dir)][str(self.new_manifest)][project]["Diff match"][new_sha] = {
                    "message": new_commit_message,
                    "matched": {
                        old_sha: old_commit_message,
                    },
                    "ratio": ratio
                }
                return ratio

    def match_summary(self, project, new_commit, old_commits):
        """
        Matches the summary of a new commit with the summaries of old commits.
        """
        new_sha, new_commit_message, _, _ = new_commit
        for old_sha, old_commit_message, _, _ in old_commits:
            normalized_old_commit_message = re.sub(self.backport_regex, '', re.sub(
                self.normalize_regex, '', old_commit_message)).lower()
            normalized_new_commit_message = re.sub(self.backport_regex, '', re.sub(
                self.normalize_regex, '', new_commit_message)).lower()
            if normalized_old_commit_message == normalized_new_commit_message and len(old_commit_message) > 10:
                self.matched_commits += 1
                self.commits[str(self.product_dir)][str(self.new_manifest)][project]["Summary match"][new_sha] = {
                    "message": new_commit_message,
                    "matched": {
                        old_sha: old_commit_message,
                    }
                }
                return True

    def show_needed_commits(self, repo_path, change_info):
        """
        Determine 'missing' commits for a given project based on two commit
        SHAs for the project. This is done by doing a 'git log' on the
        symmetric difference of the two commits in forward and reversed order,
        then comparing the summary content, dates and diffs from the latter to
        find a matching entry in the former, which are all strong indications
        that the commit was properly merged into the project at the time of the
        target manifest.
        Print out any possible matches along with any 'missing' commits to
        allow user to determine what might still need to be merged forward.
        """

        # We skip any projects which:
        # - are explicitly ignored
        # - don't match the targeted project (if a project is being targeted)
        # - are third party godeps
        if repo_path in self.ignore_projects or (
                self.targeted_project and not re.search(
                    rf'\b{self.targeted_project}\b', repo_path
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
            old_results = subprocess.check_output(
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
            with concurrent.futures.ThreadPoolExecutor() as executor:
                old_commits = list(executor.map(
                    get_commit_details, old_results.split("\n")))

        try:
            new_results = subprocess.check_output(
                missing + [f'{new_commit}...{old_commit}'],
                cwd=project_dir, stderr=subprocess.STDOUT
            ).decode().strip()

        except subprocess.CalledProcessError as exc:
            traceback.print_exc()
            raise RuntimeError(f'The "git log" command for project "{repo_path}" '
                               f'failed: {exc.stdout}') from exc

        new_commits = []
        if new_results:
            with concurrent.futures.ThreadPoolExecutor() as executor:
                new_commits = list(executor.map(
                    get_commit_details, new_results.split("\n")))

        project_name = self.get_project_name(repo_path)
        self.commits[str(self.product_dir)][str(self.new_manifest)][project_name] = default_dict_factory()

        if new_commits:
            for commit in new_commits:
                new_sha, new_commit_message, _, _ = commit
                if any(
                    c.startswith(new_sha[:7]) for c in self.ignored_commits
                ):
                    continue

                backports = self.backports_of(get_tickets(new_commit_message))
                is_a_backport = False
                if backports:
                    with pushd(project_dir):
                        gitlog = subprocess.Popen(
                            ['git', 'log', '--oneline', new_commit],
                            stdout=subprocess.PIPE)
                        try:
                            matches = subprocess.check_output(
                                ['grep', '-E'] + ['|'.join(backports)], stdin=gitlog.stdout
                            ).decode("ascii").strip().split("\n")
                            if len(matches) > 0:
                                is_a_backport = True
                        except subprocess.CalledProcessError as exc:
                            if exc.returncode == 1:
                                # grep most likely failed to find a match.
                                pass
                            else:
                                self.log.warning("Exception:", exc.output)

                if is_a_backport:
                    self.matched_commits += 1
                    self.commits[str(self.product_dir)][str(self.new_manifest)][project_name]["Backport"][new_sha] = {
                        "message": new_commit_message,
                        "backports": {
                            match.split(" ")[0]: match.split(" ", 1)[1] for match in matches
                        }
                    }
                    continue

                if (self.match_summary(project_name, commit, old_commits) or
                        self.match_date(project_name, commit, old_commits) or
                        self.match_diff(project_name, commit, old_commits)):
                    continue

                self.commits[str(self.product_dir)][str(self.new_manifest)][project_name]["Missing"][new_sha] = {
                    "message": new_commit_message,
                }
                self.missing_commits += 1


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
    parser.add_argument('-p', '--project', dest='targeted_project',
                        help='Specific project to target - will process all if unspecified')
    parser.add_argument('-i', '--ignore', dest='ignore_file',
                        help='File to store "ignored" commits',
                        default='ignored_commits.txt')
    parser.add_argument('-m', '--merge', dest='merge_file',
                        help='File to store "merged" projects info',
                        default='merged_projects.txt')
    parser.add_argument('product', help='Product to check')
    parser.add_argument('old_manifest', help='Base manifest to check against')
    parser.add_argument('new_manifest', help='Current manifest to verify')
    parser.add_argument('--reporef_dir',
                        help='Path to repo mirror reference directory')
    parser.add_argument('--manifest_repo', help='Git URL to manifest repo')
    args = parser.parse_args()

    # Set up logging
    logger = logging.getLogger(__name__)
    logger.setLevel(logging.DEBUG)

    ch = logging.StreamHandler()
    if not args.debug:
        ch.setLevel(logging.INFO)

    logger.addHandler(ch)

    # Read in 'ignored' commits
    # Form of each line is: '<project> <commit SHA> <optional comment>'
    ignored_commits = list()

    try:
        with open(args.ignore_file) as fh:
            for entry in fh.readlines():
                if entry.startswith('#'):
                    continue   # Skip comments
                try:
                    _, commit = entry.split()[0:2]
                except ValueError:
                    logger.warning(f'Malformed line in ignored commits file, '
                                   f'skipping: {entry}')
                else:
                    ignored_commits.append(commit)
    except FileNotFoundError:
        logger.warning(f'Ignored commits file, {args.ignore_file}, '
                       f'not found.  Continuing...')

    # Read in 'merged' projects information
    # Form of each line is: '<merged project> [<original project> [...]]'
    pre_merge = list()
    post_merge = list()
    merge_map = dict()

    try:
        with open(args.merge_file) as fh:
            for entry in fh.readlines():
                if entry.startswith('#'):
                    continue   # Skip comments

                try:
                    post, *pre = entry.split()
                except ValueError:
                    logger.warning(f'Empty line in merged projects file, '
                                   f'skipping')
                else:
                    if pre:
                        pre_merge.extend(pre)
                        post_merge.append(post)
                        merge_map[post] = pre
                    else:
                        logger.warning(f'Malformed line in merged projects '
                                       f'file, skipping: {entry}')
    except FileNotFoundError:
        logger.warning(f'Merged projects file, {args.merge_file}, '
                       f'not found.  Continuing...')

    # Setup file paths and search for missing commits
    product_dir = pathlib.Path(args.product)
    old_manifest = pathlib.Path(args.old_manifest)
    new_manifest = pathlib.Path(args.new_manifest)
    reporef_dir = pathlib.Path(args.reporef_dir)

    try:
        commit_checker = MissingCommits(
            logger, product_dir, old_manifest, new_manifest, args.manifest_repo,
            reporef_dir, ignored_commits, pre_merge, post_merge, merge_map,
            args.targeted_project, args.debug
        )
        if commit_checker.missing_commits > 0:
            sys.exit(1)
    except Exception as exc:
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
