#!/usr/bin/env python3.6
"""
Compare two manifests from a given product to see if there are any
potential commits in the older manifest which did not get included
into the newer manifest.  This will assist in determining if needed
fixes or changes have been overlooked being added to newer releases.
The form of the manifest filenames passed is a relative path based
on their location in the manifest repository (e.g. released/4.6.1.xml).
"""
import os
import argparse
import io
import logging
import os.path
import pathlib
import re
import subprocess
import sys
import contextlib
import traceback
from distutils.spawn import find_executable

import dulwich.patch
import dulwich.porcelain
import dulwich.repo
import lxml.etree

from manifest_tools.scripts.jira_util import connect_jira, get_tickets


@contextlib.contextmanager
def pushd(new_dir):
    old_dir = os.getcwd()
    os.chdir(new_dir)

    try:
        yield
    finally:
        os.chdir(old_dir)


DEVNULL = open(os.devnull, 'w')

class MissingCommits:
    """"""

    def __init__(self, logger, product_dir, old_manifest, new_manifest,
                 manifest_repo, reporef_dir, ignored_commits,
                 pre_merge, post_merge, merge_map):
        """
        Store key information into instance attributes and determine
        path of 'repo' program
        """

        self.missing_commits_found = False

        self.log = logger
        self.product_dir = product_dir
        self.old_manifest = old_manifest
        self.new_manifest = new_manifest
        self.manifest_repo = manifest_repo
        self.reporef_dir = reporef_dir
        self.ignored_commits = ignored_commits
        self.pre_merge = pre_merge
        self.post_merge = post_merge
        self.merge_map = merge_map

        # Projects we don't care about
        self.ignore_projects = ['testrunner', 'libcouchbase']

        self.repo_bin = find_executable('repo')

        # We check jira and ignore tickets which are flagged "is a backport of" a ticket in the newer release
        try:
            self.jira = connect_jira()
        except Exception:
            self.log.critical("Jira connection failed")
            sys.exit(1)


    def backports_of(self, tickets):
        """For a list of tickets, gather any outward links flagged "is a backport of" in Jira
        and return a combined listing of the ticket references"""

        backports = []
        for ticket in tickets:
            try:
                jira_ticket = self.jira.issue(ticket)
                for issuelink in jira_ticket.raw["fields"]["issuelinks"]:
                    if issuelink["type"]["outward"] == "is a backport of":
                        # Ensure we're looking at the actual backport ticket,
                        # not a ticket that was itself backported
                        if "outwardIssue" in issuelink:
                            backports.append(issuelink["outwardIssue"]["key"])
            except Exception as exc:
                traceback.print_exc()
                self.log.error(f"Jira ticket retrieval failed for {ticket}")
                sys.exit(1)

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
            self.log.warning(f'"{self.product_dir}" exists and is not a directory, '
                  f'removing...')
            try:
                self.product_dir.unlink()
            except OSError as exc:
                self.log.error(
                    f'Unable to delete "{self.product_dir}" file/link: '
                    f'{exc.message}'
                )
                sys.exit(1)

        if not self.product_dir.exists():
            try:
                self.product_dir.mkdir()
            except OSError as exc:
                self.log.error(
                    f'Unable to create "{self.product_dir}" directory: '
                    f'{exc.message}'
                )
                sys.exit(1)

        try:
            cmd = [self.repo_bin, 'init', '-u',
                   self.manifest_repo,
                   '-g', 'all', '-m', self.new_manifest]
            if self.reporef_dir is not None:
                cmd.extend(['--reference', self.reporef_dir])
            subprocess.check_output(cmd,
                                    cwd=self.product_dir, stderr=subprocess.STDOUT
                                    )
        except subprocess.CalledProcessError as exc:
            self.log.error(f'The "repo init" command failed: {exc.output}')
            sys.exit(1)

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
            self.log.error(f'The "repo sync" command failed: {exc.output}')
            sys.exit(1)

        # This is needed for manifests with projects not locked down
        # (e.g. spock.xml)
        try:
            with open('new.xml', 'w') as fh:
                subprocess.check_call(
                    [self.repo_bin, 'manifest', '-r'],
                    stdout=fh, cwd=self.product_dir
                )
        except subprocess.CalledProcessError as exc:
            self.log.error(f'The "repo manifest -r" command failed: {exc.output}')
            sys.exit(1)

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
            self.log.error(f'The "repo diffmanifests" command failed: {exc.output}')
            sys.exit(1)

        return [
            line for line in diffs.strip().split('\n')
            if not line.startswith(' ')
        ]

    def generate_diff(self, repo_path, commit_sha):
        """"""

        return None  # Short-circuit

        project_dir = self.product_dir / repo_path
        repo = dulwich.repo.Repo(str(project_dir.resolve()))

        commit = repo[bytes(commit_sha, 'utf-8')]
        prev_commit = repo[commit.parents[0]]

        fh = io.BytesIO()
        dulwich.patch.write_tree_diff(fh, repo.object_store, prev_commit.tree,
                                      commit.tree)

        return [line for line in fh.getvalue().decode().split('\n')]

    @staticmethod
    def compare_summaries(old_summary, new_summary):
        """"""

        return True if old_summary == new_summary else False

    """
    Pre-compiled regex for SHA
    """
    sha_regex = re.compile(r'[0-9a-f]{40}')

    """
    Pre-compiled regex for tag reference
    """
    tag_regex = re.compile(r'refs/tags/.*')

    def get_commit_sha(self, project, commit):
        """
        Find the latest commit SHA from the given branch/tag/SHA
        """

        # If 'commit' is already a SHA, just return it
        if MissingCommits.sha_regex.fullmatch(commit) is not None:
            # Already a SHA, just return it
            return commit

        # Not a SHA, so we'll ask git to turn it into a SHA. If 'commit'
        # looks like a tag reference, use it directly; otherwise, assume
        # it's a branch name, and prepend the remote name to disambiguate.
        if MissingCommits.tag_regex.fullmatch(commit) is not None:
            git_ref = commit
        else:
            # $REPO_REMOTE is set by 'repo forall'
            git_ref = f'$REPO_REMOTE/{commit}'

        try:
            commit_sha = subprocess.check_output(
                [self.repo_bin, 'forall', project, '-c',
                 f'git show-ref --hash {git_ref}'],
                cwd=self.product_dir, stderr=subprocess.STDOUT
            ).decode()
        except subprocess.CalledProcessError as exc:
            self.log.error(f'The "repo forall" command failed: {exc.output}')
            sys.exit(1)

        return commit_sha.strip()

    def show_needed_commits(self, repo_path, change_info):
        """
        Determine 'missing' commits for a given project based on
        two commit SHAs for the project.  This is done by doing
        a 'git log' on the symmetric difference of the two commits
        in forward and reversed order, then comparing the summary
        content from the latter to find a matching entry in the
        former, which is a strong indication that the commit was
        properly merged into the project at the time of the target
        manifest.
        Print out any possible matches along with any 'missing'
        commits to allow user to determine what might still need
        to be merged forward.
        """

        if repo_path in self.ignore_projects:
            return
        # Also don't care about third-party Go stuff
        if repo_path.startswith("godeps"):
            return

        old_commit, new_commit, old_diff, new_diff = change_info
        missing = [
            '/usr/bin/git', 'log', '--oneline', '--cherry-pick',
            '--right-only', '--no-merges'
        ]

        old_commit = self.get_commit_sha(repo_path, old_commit)
        new_commit = self.get_commit_sha(repo_path, new_commit)

        project_dir = self.product_dir / repo_path
        try:
            old_results = subprocess.check_output(
                missing + [f'{old_commit}...{new_commit}'],
                cwd=project_dir, stderr=subprocess.STDOUT
            ).decode()
        except subprocess.CalledProcessError as exc:
            self.log.error(f'The "git log" command for project "{repo_path}" '
                  f'failed: {exc.stdout}')
            sys.exit(1)

        if old_results:
            rev_commits = old_results.strip().split('\n')
        else:
            rev_commits = list()

        try:
            new_results = subprocess.check_output(
                missing + [f'{new_commit}...{old_commit}'],
                cwd=project_dir, stderr=subprocess.STDOUT
            ).decode()
        except subprocess.CalledProcessError as exc:
            self.log.error(f'The "git log" command for project "{repo_path}" '
                  f'failed: {exc.stdout}')
            sys.exit(1)

        backport_message = ""
        missing_message = ""

        if new_results:
            for commit in new_results.strip().split('\n'):
                sha, comment = commit.split(' ', 1)

                if any(c.startswith(sha[:7]) for c in self.ignored_commits):
                    continue

                match = True
                for rev_commit in rev_commits:
                    rev_sha, rev_comment = rev_commit.split(' ', 1)
                    if self.compare_summaries(rev_comment, comment):
                        break
                else:
                    match = False
                backports = self.backports_of(get_tickets(comment))
                is_a_backport = False
                if backports:
                    with pushd(self.product_dir / repo_path):
                        with open('.git/HEAD') as f:
                            head = f.read().strip()
                        gitlog = subprocess.Popen(
                            ['git', 'log', '--oneline', new_commit], stdout=subprocess.PIPE)
                        try:
                            matches = subprocess.check_output(
                                ["grep", "-E"] + ['|'.join(backports)], stdin=gitlog.stdout).decode("ascii").strip().split("\n")
                            if len(matches) > 0:
                                is_a_backport = True
                        except subprocess.CalledProcessError as exc:
                            if exc.returncode == 1:
                                # grep most likely failed to find a match.
                                pass
                            else:
                                self.log.warning("Exception:", exc.output)

                # If it's a backport, keep log for later but don't count it as
                # a missing commit
                if is_a_backport:
                    backport_message += (
                        f'                 [Backport] {sha[:8]} {comment:.80}\n'
                        f'                        of: '
                    )
                    backport_message += '\n                            '.join(
                        [f'{x:.80}' for x in matches]
                    )
                    backport_message += '\n'
                    continue

                # At this point we know we have something to report. Save the
                # message.
                if match:
                    missing_message += (
                        f'    [Possible commit match] {sha[:8]} {comment:.80}\n'
                        f'              Check commit: {rev_sha[:8]} {rev_comment:.80}\n'
                    )
                else:
                    missing_message += (
                        f'          [No commit match] {sha[:8]} {comment:.80}\n'
                    )

            # Print project header, if anything to report
            if missing_message != "" or backport_message != "":
                self.log.info("")
                self.log.info(f'Project {repo_path}:')

            if missing_message != "":
                self.log.info("")
                self.log.info(missing_message)
                self.missing_commits_found = True

            # We believe this to be working now, so stop outputting the
            # message - makes it too hard to see actual issues.
            # I'm leaving the code in place to display this if we want
            # it again in future. - Ceej Jun 06 2021
            if backport_message != "":
                self.log.info("")
                self.log.info("This project has backports that were correctly identified")

    def determine_diffs(self):
        """
        This manages the main workflow:
         - Sync the repo checkout to the target release/branch
         - Generate the diffs between the two manifests
         - Determine any "missing" commits by comparing SHAs
           for each project via 'git log'; this includes knowing
           about merged projects and handling them correctly
        """

        self.repo_sync()
        diffs = self.diff_manifests()
        changes = dict()

        # Create dictionary with all the relevant changes; this avoids
        # any added or removed projects that were not part of a merge
        # process at some point in the past
        for entry in diffs:
            if entry.startswith('A '):
                _, repo_path, current_commit = entry.split()

                if repo_path in self.post_merge:
                    changes[repo_path] = (
                        'added', current_commit,
                        self.generate_diff(repo_path, current_commit)
                    )
            elif entry.startswith('R '):
                _, repo_path, final_commit = entry.split()

                if repo_path in self.pre_merge:
                    changes[repo_path] = (
                        'removed', final_commit,
                        self.generate_diff(repo_path, final_commit)
                    )
            elif entry.startswith('C '):
                _, repo_path, old_commit, new_commit = entry.split()
                changes[repo_path] = (
                    'changed', old_commit, new_commit,
                    self.generate_diff(repo_path, old_commit),
                    self.generate_diff(repo_path, new_commit)
                )
            else:
                self.log.warning(f'Unhandled entry, skipping: {entry}')

        self.log.info(f"\n\n* Missing commits from {self.old_manifest} "
                      f"to {self.new_manifest}...\n")

        # Perform commit diffs, handling merged projects by diffing
        # the merged project against each of the projects the were
        # merged into it
        for repo_path, change_info in changes.items():
            if change_info[0] == 'changed':
                change_info = change_info[1:]
                self.show_needed_commits(repo_path, change_info)
            elif change_info[0] == 'added':
                _, new_commit, new_diff = change_info

                for pre in self.merge_map[repo_path]:
                    _, old_commit, old_diff = changes[pre]
                    change_info = (old_commit, new_commit, old_diff, new_diff)
                    self.show_needed_commits(repo_path, change_info)

        if not self.missing_commits_found:
            self.log.info("")
            self.log.info("No missing commits discovered!\n")
        self.log.info("")


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
                    project, commit = entry.split()[0:2]
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

    miss_comm = MissingCommits(
        logger, product_dir, old_manifest, new_manifest, args.manifest_repo,
        reporef_dir, ignored_commits, pre_merge, post_merge, merge_map
    )
    miss_comm.determine_diffs()

    if miss_comm.missing_commits_found:
        sys.exit(1)


if __name__ == '__main__':
    main()
