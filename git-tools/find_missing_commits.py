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
import io
import logging
import os.path
import pathlib
import re
import subprocess
import sys

from distutils.spawn import find_executable

import dulwich.patch
import dulwich.porcelain
import dulwich.repo
import lxml.etree


class Manifest:
    """FILL IN"""

    def __init__(self, product_dir, manifest):
        """Initialize parameters for metadata storage"""

        self.manifest = str(product_dir / '.repo/manifests' / manifest)
        self.remotes = None
        self.projects = None

    def get_remotes(self, tree):
        """Acquire the Git remotes for the repositories"""

        remotes = dict()

        for remote in tree.findall('remote'):
            remote_name = remote.get('name')
            remote_url = remote.get('fetch')

            # Skip incomplete/invalid remotes
            if remote_name is None or remote_url is None:
                continue

            remotes[remote_name] = remote_url

        # Get default remote
        default_remote = tree.find('default')
        default_remote_name = default_remote.get('remote')
        remotes['default'] = remotes[default_remote_name]

        self.remotes = remotes

    def get_projects(self, tree):
        """Acquire information for repositories to be archived"""

        projects = dict()

        for project in tree.findall('project'):
            project_name = project.get('name')
            project_remote = project.get('remote')
            project_revision = project.get('revision')
            project_path = project.get('path')

            # Skip incomplete/invalid projects
            if project_name is None:
                continue

            if project_remote is None:
                project_remote = self.remotes['default']

            if project_path is None:
                project_path = project_name

            projects[project_name] = {
                'remote': project_remote,
                'revision': project_revision,
                'path': project_path,
            }

        self.projects = projects

    def get_metadata(self):
        """
        Acquire the manifest, then parse and extract information for
        the remotes and projects, needed to retrieve the repositories
        to be archived
        """

        tree = lxml.etree.parse(self.manifest)

        self.get_remotes(tree)
        self.get_projects(tree)


class MissingCommits:
    """"""

    def __init__(self, logger, product_dir, old_manifest, new_manifest,
                 ignored_commits, pre_merge, post_merge, merge_map):
        """
        Store key information into instance attributes and determine
        path of 'repo' program
        """

        self.log = logger
        self.product_dir = product_dir
        self.old_manifest = old_manifest
        self.new_manifest = new_manifest
        self.ignored_commits = ignored_commits
        self.pre_merge = pre_merge
        self.post_merge = post_merge
        self.merge_map = merge_map

        # Projects where git diffs are allowed to fail
        self.safe_projects = ['testrunner']

        self.repo_bin = find_executable('repo')

        self.old_mf_data = Manifest(product_dir, old_manifest)
        self.old_mf_data.get_metadata()

    def repo_sync(self):
        """
        Initialize and sync a repo checkout based on the target
        manifest; generate a new manifest with fixed SHAs in case
        the target contains branches (e.g. master) via the command
        'repo manifest -r' so 'git log' will work properly
        """

        # Create a 'product' directory to contain the repo checkout
        if self.product_dir.exists() and not self.product_dir.is_dir():
            print(f'"{self.product_dir}" exists and is not a directory, '
                  f'removing...')
            try:
                self.product_dir.unlink()
            except OSError as exc:
                print(
                    f'Unable to delete "{self.product_dir}" file/link: '
                    f'{exc.message}'
                )
                sys.exit(1)

        if not self.product_dir.exists():
            try:
                self.product_dir.mkdir()
            except OSError as exc:
                print(
                    f'Unable to create "{self.product_dir}" directory: '
                    f'{exc.message}'
                )
                sys.exit(1)

        try:
            subprocess.check_call(
                [self.repo_bin, 'init', '-u',
                 'http://github.com/couchbase/manifest',
                 '-g', 'all', '-m', self.new_manifest],
                cwd=self.product_dir, stderr=subprocess.STDOUT
            )
        except subprocess.CalledProcessError as exc:
            print(f'The "repo init" command failed: {exc.output}')
            sys.exit(1)

        try:
            subprocess.check_call(
                [self.repo_bin, 'sync', '--jobs=6', '--force-sync'],
                cwd=self.product_dir, stderr=subprocess.STDOUT
            )
        except subprocess.CalledProcessError as exc:
            print(f'The "repo sync" command failed: {exc.output}')
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
            print(f'The "repo manifest -r" command failed: {exc.output}')
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
            print(f'The "repo diffmanifests" command failed: {exc.output}')
            sys.exit(1)

        return [
            line for line in diffs.strip().split('\n')
            if not line.startswith(' ')
        ]

    def clone_removed_repo(self, repo_path):
        """"""

        repo_name = os.path.basename(repo_path)
        print(f'Repo name: {repo_name}')
        repo_remote = self.old_mf_data.projects[repo_path]['remote']
        print(f'Repo remote: {repo_remote}')
        target_dir = os.path.join(self.product_dir, repo_path)

        if not os.path.exists(target_dir):
            dulwich.porcelain.clone(f'{repo_remote}/{repo_name}',
                                    target=target_dir, checkout=True)

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

    @staticmethod
    def compare_diffs(old_diff, new_diff):
        """"""

        for old_line, new_line in zip(old_diff, new_diff):
            if old_line.startswith('index') or old_line.startswith('@@ '):
                continue

            if old_line != new_line:
                return False
        else:
            return True

    def get_commit_sha(self, project, branch):
        """
        Find the latest commit SHA from the given branch
        """

        try:
            commit_sha = subprocess.check_output(
                [self.repo_bin, 'forall', project, '-c',
                 f'git show-ref --hash $REPO_REMOTE/{branch}'],
                cwd=self.product_dir, stderr=subprocess.STDOUT
            ).decode()
        except subprocess.CalledProcessError as exc:
            print(f'The "repo forall" command failed: {exc.output}')
            sys.exit(1)

        return commit_sha.strip()

    def show_needed_commits(self, project_dir, change_info):
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

        old_commit, new_commit, old_diff, new_diff = change_info
        missing = [
            '/usr/bin/git', 'log', '--oneline', '--cherry-pick',
            '--right-only', '--no-merges'
        ]

        sha_regex = re.compile(r'^[0-9a-f]{40}$')

        if sha_regex.match(old_commit) is None:
            old_commit = self.get_commit_sha(project_dir.name, old_commit)

        if sha_regex.match(new_commit) is None:
            new_commit = self.get_commit_sha(project_dir.name, new_commit)

        try:
            old_results = subprocess.check_output(
                missing + [f'{old_commit}...{new_commit}'],
                cwd=project_dir, stderr=subprocess.STDOUT
            ).decode()
        except subprocess.CalledProcessError as exc:
            print(f'The "git log" command for project "{project_dir.name}" '
                  f'failed: {exc.stdout}')

            if project_dir.name in self.safe_projects:
                return
            else:
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
            print(f'The "git log" command for project "{project_dir.name}" '
                  f'failed: {exc.stdout}')

            if project_dir in self.safe_projects:
                return
            else:
                sys.exit(1)

        if new_results:
            print(f'Project {project_dir.name}:')

            for commit in new_results.strip().split('\n'):
                sha, comment = commit.split(' ', 1)

                match = True
                for rev_commit in rev_commits:
                    rev_sha, rev_comment = rev_commit.split(' ', 1)

                    if self.compare_summaries(rev_comment, comment):
                        break

                    # if self.compare_diffs(old_diff, new_diff):
                    #     break
                else:
                    match = False

                if match:
                    print(f'    [Possible commit match] {sha[:7]} {comment}')
                    print(f'        Check commit: {rev_sha[:7]} '
                          f'{rev_comment}')
                else:
                    if not any(c.startswith(sha)
                               for c in self.ignored_commits):
                        print(f'    [No commit match      ] {sha[:7]} '
                              f'{comment}')

            print()

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
                    # self.clone_removed_repo(repo_path)
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

        # Perform commit diffs, handling merged projects by diffing
        # the merged project against each of the projects the were
        # merged into it
        for repo_path, change_info in changes.items():
            if change_info[0] == 'changed':
                change_info = change_info[1:]
                project_dir = self.product_dir / repo_path
                self.show_needed_commits(project_dir, change_info)
            elif change_info[0] == 'added':
                _, new_commit, new_diff = change_info
                project_dir = self.product_dir / repo_path

                for pre in self.merge_map[repo_path]:
                    _, old_commit, old_diff = changes[pre]
                    change_info = (old_commit, new_commit, old_diff, new_diff)
                    self.show_needed_commits(project_dir, change_info)


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

    args = parser.parse_args()

    # Set up logging
    logger = logging.getLogger(__name__)
    logger.setLevel(logging.DEBUG)

    ch = logging.StreamHandler()
    if not args.debug:
        ch.setLevel(logging.INFO)

    logger.addHandler(ch)

    # Read in 'ignored' commits
    # Form of each line is: '<project> <commit SHA>'
    ignored_commits = list()

    try:
        with open(args.ignore_file) as fh:
            for entry in fh.readlines():
                if entry.startswith('#'):
                    continue   # Skip comments

                try:
                    project, commit = entry.split()
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

    miss_comm = MissingCommits(
        logger, product_dir, old_manifest, new_manifest, ignored_commits,
        pre_merge, post_merge, merge_map
    )
    miss_comm.determine_diffs()


if __name__ == '__main__':
    main()
