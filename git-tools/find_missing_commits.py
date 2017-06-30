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
import logging
import pathlib
import subprocess
import sys

from distutils.spawn import find_executable


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
                cwd=self.product_dir, stderr=subprocess.STDOUT,
                encoding='utf-8', universal_newlines=True
            )
        except subprocess.CalledProcessError as exc:
            print(f'The "repo diffmanifests" command failed: {exc.output}')
            sys.exit(1)

        return [
            line for line in diffs.strip().split('\n')
            if not line.startswith(' ')
        ]

    def show_needed_commits(self, project_dir, old_commit, new_commit):
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

        missing = [
            '/usr/bin/git', 'log', '--oneline', '--cherry-pick',
            '--right-only', '--no-merges'
        ]

        try:
            old_results = subprocess.check_output(
                missing + [f'{old_commit}...{new_commit}'],
                cwd=project_dir, stderr=subprocess.STDOUT,
                encoding='utf-8', universal_newlines=True
            )
        except subprocess.CalledProcessError as exc:
            print(f'The "git log" command for project "{project_dir.name}" '
                  f'failed: {exc.stdout}')

            if project_dir.name in self.safe_projects:
                return
            else:
                sys.exit(1)

        rev_commits = old_results.strip().split('\n')

        try:
            new_results = subprocess.check_output(
                missing + [f'{new_commit}...{old_commit}'],
                cwd=project_dir, stderr=subprocess.STDOUT,
                encoding='utf-8', universal_newlines=True
            )
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
                match = [s for s in rev_commits if comment in s]

                if match:
                    print(f'    [Possible commit match] {commit}')
                    print(f'        Check commit: {match[0]}')
                else:
                    if not any(c.startswith(sha)
                               for c in self.ignored_commits):
                        print(f'    [No commit match      ] {commit}')

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
        for entry, change_info in changes.items():
            if change_info[0] == 'changed':
                _, old_commit, new_commit = change_info
                project_dir = self.product_dir / entry
                self.show_needed_commits(project_dir, old_commit, new_commit)
            elif change_info[0] == 'added':
                _, new_commit = change_info
                project_dir = self.product_dir / entry

                for pre in self.merge_map[entry]:
                    _, old_commit = changes[pre]
                    self.show_needed_commits(project_dir, old_commit,
                                             new_commit)


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
