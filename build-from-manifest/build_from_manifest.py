#!/usr/bin/env python3.6

"""
Program to generate build information along with a source tarball
for building when any additional changes have happened for a given
input build manifest
"""

import argparse
import contextlib
import gzip
import json
import os
import os.path
import pathlib
import shutil
import subprocess
import sys
import tarfile
import time
import xml.etree.ElementTree as EleTree

from datetime import datetime
from pathlib import Path
from subprocess import PIPE, STDOUT, run
from typing import Union


# Context manager for handling a given set of code/commands
# being run from a given directory on the filesystem
@contextlib.contextmanager
def pushd(new_dir):
    old_dir = os.getcwd()
    os.chdir(new_dir)

    try:
        yield
    finally:
        os.chdir(old_dir)


# Save current path for program
script_dir = os.path.dirname(os.path.realpath(__file__))


class ManifestBuilder:
    """
    Handle creating a new manifest from a given input manifest,
    along with other files needed for a new build
    """

    # Files to be generated in the top-level workspace directory
    output_filenames = [
        'build.properties',
        'build-properties.json',
        'build-manifest.xml',
        'source.tar',
        'source.tar.gz',
        'CHANGELOG'
    ]

    def __init__(self, args):
        """
        Initialize from the arguments and set up a set of additional
        attributes for handling key data
        """

        self.manifest = pathlib.Path(args.manifest)
        self.manifest_project = args.manifest_project
        self.push_manifest_project = args.push_manifest_project
        self.build_manifests_org = args.build_manifests_org
        self.force = args.force
        self.push = not args.no_push

        self.output_files = dict()
        self.product = None
        self.product_path = None
        self.prod_name = None
        self.input_manifest = None
        self.manifests = None
        self.product_config = None
        self.manifest_config = None

        self.product_branch = None
        self.start_build = None
        self.type = None
        self.parent = None
        self.parent_branch = None
        self.go_version = None
        self.build_job = None
        self.platforms = None
        self.build_manifest_filename = None
        self.branch_exists = 0
        self.version = None
        self.release = None
        self.last_build_num = 0
        self.build_num = None

    def prepare_files(self):
        """
        For the set of files to be generated, ensure any current
        versions of them in the filesystem are removed, and keep
        track of them via a dictionary
        """

        for name in self.output_filenames:
            output_file = pathlib.Path(name).resolve()

            if output_file.exists():
                output_file.unlink()

            self.output_files[name] = output_file

    @staticmethod
    def update_manifest_repo():
        """
        Update the manifest repository
        """

        print('Updating manifest repository...')
        run(['git', 'fetch', '--all'], check=True)
        run(['git', 'checkout', '-B', 'master', 'origin/master'], check=True)

    def parse_manifest(self):
        """
        Parse the input manifest (via xml.ElementTree)
        """

        if not self.manifest.exists():
            print(f'Manifest "{self.manifest}" does not exist!')
            sys.exit(3)

        self.input_manifest = EleTree.parse(self.manifest)

    def determine_product_path(self):
        """
        Determine the product path from the given input manifest
        """

        for parent in self.manifest.parents:
            if (parent / 'product-config.json').exists():
                self.product_path = str(parent)
                break
        else:
            # For legacy reasons, 'top-level' manifests
            # are couchbase-server
            self.product_path = 'couchbase-server'


    def get_product_and_manifest_config(self):
        """
        Determine product config information related to input manifest,
        along with the specific manifest information as well
        """

        config_name = pathlib.Path(self.product_path) / 'product-config.json'

        try:
            with open(config_name) as fh:
                self.product_config = json.load(fh)
        except FileNotFoundError:
            self.product_config = dict()

        override_product = self.product_config.get('product')
        if override_product is not None:
            # Override product (and product_path) if set in product-config.json
            self.product = override_product
            self.product_path = override_product.replace('::', '/')
        else:
            # Otherwise, product name is derived from product path
            self.product = self.product_path.replace('/', '::')

        # Save the "basename" of the product name as prod_name
        self.prod_name = self.product.split('::')[-1]

        self.manifests = self.product_config.get('manifests', dict())
        self.manifest_config = self.manifests.get(str(self.manifest), dict())

    def do_manifest_stuff(self):
        """
        Handle the various manifest tasks:
          - Clone the manifest repository if it's not already there
          - Update the manifest repository to latest revision
          - Parse the manifest and gather product and manfiest config
            information
        """

        manifest_dir = pathlib.Path('manifest')

        # If we've been requested to use a different manifest repository,
        # delete the manifest directory so that the next block will
        # re-clone it
        if manifest_dir.exists():
            with pushd(manifest_dir):
                url = run(
                    ['git', 'ls-remote', '--get-url', 'origin'],
                    check=True, stdout=PIPE
                ).stdout.decode().strip()
            if url != self.manifest_project:
                print('"manifest" dir pointing to different remote, removing..')
                shutil.rmtree(manifest_dir)

        if not manifest_dir.exists():
            run(['git', 'clone', self.manifest_project, 'manifest'],
                check=True)

        with pushd(manifest_dir):
            self.update_manifest_repo()
            self.parse_manifest()
            self.determine_product_path()
            self.get_product_and_manifest_config()

    def update_submodules(self, module_projects):
        """
        Update all existing submodules for given repo sync
        """

        module_projects_dir = pathlib.Path('module_projects').resolve()

        if not module_projects_dir.exists():
            module_projects_dir.mkdir()

        with pushd(module_projects_dir):
            print('"module_projects" is set, calling update_manifest_from_submodules...')
            # https://code-maven.com/python-capture-stdout-stderr-exit
            # Do the following so the output from the sub-script's stderr
            # and stdout aren't all out of order.
            proc = subprocess.Popen(
                [f'{script_dir}/update_manifest_from_submodules',
                 f'../manifest/{self.manifest}']
                + module_projects, stdout=PIPE, stderr=STDOUT
            )
            print(proc.communicate()[0].decode('UTF-8'))
            if proc.returncode != 0:
                print("\n\nError {proc.returncode} running update_manifest_from_submodules!")
                sys.exit(5)

            with pushd(module_projects_dir.parent / 'manifest'):
                # I have no idea why this call is required, but
                # 'git diff-index' behaves erratically without it
                run(['git', 'status'], check=True, stdout=PIPE)

                rc = run(['git', 'diff-index', '--quiet', 'HEAD']).returncode

                if rc:
                    if self.push:
                        print(f'Pushing updated input manifest upstream... '
                              f'return code was {rc}')
                        run([
                            'git', 'commit', '-am', f'Automated update of '
                            f'{self.product} from submodules'
                        ], check=True)
                        run([
                            'git', 'push',
                            self.push_manifest_project,
                            'refs/heads/master:refs/heads/master'
                        ], check=True)
                    else:
                        print('Skipping push of updated input manifest '
                              'due to --no-push')
                else:
                    print('Input manifest left unchanged after updating '
                          'submodules')

    def set_relevant_parameters(self):
        """
        Determine various key parameters needed to pass on
        for building the product
        """

        self.product_branch = self.manifest_config.get('branch', 'master')
        self.start_build = self.manifest_config.get('start_build', 1)
        self.type = self.manifest_config.get('type', 'production')
        self.parent = self.manifest_config.get('parent')
        self.parent_branch = \
            self.manifests.get(self.parent, {}).get('branch', 'master')
        self.go_version = self.manifest_config.get('go_version')

        self.build_job = \
            self.manifest_config.get('jenkins_job', f'{self.product}-build')
        self.platforms = self.manifest_config.get('platforms', [])

    def set_build_parameters(self):
        """
        Determine various build parameters for given input manifest,
        namely version and release
        """

        build_element = self.input_manifest.find('./project[@name="build"]')

        if build_element is None:
            print(f'Input manifest {self.manifest} has no "build" project!')
            sys.exit(4)

        vers_annot = build_element.find('annotation[@name="VERSION"]')

        if vers_annot is not None:
            self.version = vers_annot.get('value')
            print(f'Input manifest version: {self.version}')
        else:
            self.version = '0.0.0'
            print(f'Default version to 0.0.0')

        self.release = self.manifest_config.get('release', self.version)

    def perform_repo_sync(self):
        """
        Perform a repo sync based on the input manifest
        """

        product_dir = pathlib.Path(self.product_path)
        top_dir = pathlib.Path.cwd()

        if not product_dir.is_dir():
            product_dir.mkdir(parents=True)

        with pushd(product_dir):
            top_level = [
                f for f in pathlib.Path().iterdir() if str(f) != '.repo'
            ]

            child: Union[str, Path]
            for child in top_level:
                shutil.rmtree(child) if child.is_dir() else child.unlink()

            run(['repo', 'init', '-u', str(top_dir / 'manifest'), '-g', 'all',
                 '-m', str(self.manifest)], check=True)
            run(['repo', 'sync', '--jobs=6', '--force-sync'], check=True)

    def update_bm_repo_and_get_build_num(self):
        """
        Update the build-manifests repository checkout, then
        determine the next build number to use
        """

        bm_dir = pathlib.Path('build-manifests')

        if not bm_dir.is_dir():
            run(['git', 'clone', f'ssh://git@github.com/'
                 f'{self.build_manifests_org}/build-manifests'],
                check=True)

        with pushd(bm_dir):
            print('Updating the build-manifests repository...')
            run(['git', 'fetch', '--all'], check=True)
            run(['git', 'reset', '--hard', 'origin/master'], check=True)

            self.build_manifest_filename = pathlib.Path(
                f'{self.product_path}/{self.release}/{self.version}.xml'
            ).resolve()

            if self.build_manifest_filename.exists():
                last_build_manifest = EleTree.parse(
                    self.build_manifest_filename
                )
                last_bld_num_annot = last_build_manifest.find(
                    './project[@name="build"]/annotation[@name="BLD_NUM"]'
                )

                if last_bld_num_annot is not None:
                    self.last_build_num = int(last_bld_num_annot.get('value'))

            self.build_num = max(self.last_build_num + 1, self.start_build)

    def generate_changelog(self):
        """
        Generate the CHANGELOG file from any changes that have been
        found; if none are found and the build is not being forced,
        write out the properties files and exit the program
        """

        if self.build_manifest_filename.exists():
            output = run(['repo', 'diffmanifests', '--raw',
                          self.build_manifest_filename],
                         check=True, stdout=PIPE).stdout
            # Strip out non-project lines as well as projects that we
            # do not wish to trigger new builds
            lines = [x for x in output.splitlines()
                     if not (x.startswith(b' ')
                         or x.startswith(b'C testrunner')
                         or x.startswith(b'C product-metadata')
                         or x.startswith(b'C mobile-testkit'))]

            if not lines:
                if not self.force:
                    print('*\n*\n*\n'
                          f'***** No changes since last build {self.version}-'
                          f'{self.last_build_num}; not executing '
                          f'new build *****\n'
                          '*\n*\n*\n')
                    json_file = self.output_files['build-properties.json']
                    prop_file = self.output_files['build.properties']

                    with open(json_file, "w") as fh:
                        json.dump({}, fh)

                    with open(prop_file, "w") as fh:
                        fh.write('')

                    sys.exit(0)
                else:
                    print(f'No changes since last build {self.version}-'
                          f'{self.last_build_num}, but forcing new '
                          f'build anyway')

            print('Saving CHANGELOG...')
            # Need to re-run 'repo diffmanifests' without '--raw'
            # to get pretty output
            output = run(['repo', 'diffmanifests',
                          self.build_manifest_filename],
                         check=True, stdout=PIPE).stdout

            with open(self.output_files['CHANGELOG'], 'wb') as fh:
                fh.write(output)

    def update_build_manifest_annotations(self):
        """
        Update the build annotations in the new build manifest
        based on the gathered information, also generating a
        commit message for later use
        """

        build_manifest_dir = self.build_manifest_filename.parent

        if not build_manifest_dir.is_dir():
            build_manifest_dir.mkdir(parents=True)

        def insert_child_annot(parent, name, value):
            annot = EleTree.Element('annotation')
            annot.set('name', name)
            annot.set('value', value)
            annot.tail = '\n    '
            parent.insert(0, annot)

        print(f'Updating build manifest {self.build_manifest_filename}')

        with open(self.build_manifest_filename, 'w') as fh:
            run(['repo', 'manifest', '-r'], check=True, stdout=fh)

        last_build_manifest = EleTree.parse(self.build_manifest_filename)

        build_element = last_build_manifest.find('./project[@name="build"]')
        insert_child_annot(build_element, 'BLD_NUM', str(self.build_num))
        insert_child_annot(build_element, 'PRODUCT', self.product)
        insert_child_annot(build_element, 'RELEASE', self.release)

        if self.go_version is not None:
            insert_child_annot(build_element, 'GO_VERSION', self.go_version)

        version_annot = last_build_manifest.find(
            './project[@name="build"]/annotation[@name="VERSION"]'
        )

        if version_annot is None:
            insert_child_annot(build_element, 'VERSION', self.version)

        last_build_manifest.write(self.build_manifest_filename)

        return (f"{self.product} {self.release} build {self.version}-"
                f"{self.build_num}\n\n"
                f"{datetime.now().strftime('%Y/%m/%d %H:%M:%S')} "
                f"{time.tzname[time.localtime().tm_isdst]}")

    def push_manifest(self, commit_msg):
        """
        Push the new build manifest to the build-manifests
        repository, but only if it hasn't been disallowed
        """

        with pushd('build-manifests'):
            run(['git', 'add', self.build_manifest_filename], check=True)
            run(['git', 'commit', '-m', commit_msg], check=True)

            if self.push:
                run(['git', 'push', 'origin', f'HEAD:refs/heads/master'],
                    check=True)
            else:
                print('Skipping push of new build manifest due to --no-push')

    def copy_build_manifest(self):
        """
        Copy the new build manifest to the product directory
        and the root directory
        """

        print('Saving build manifest...')
        shutil.copy(self.build_manifest_filename,
                    self.output_files['build-manifest.xml'])
        # Also keep a copy of the build manifest in the tarball
        shutil.copy(self.build_manifest_filename,
                    pathlib.Path(self.product_path) / 'manifest.xml')

    def create_properties_files(self):
        """
        Generate the two properties files (JSON and INI)
        from the gathered information
        """

        print('Saving build parameters...')
        properties = {
            'PRODUCT': self.product,
            'RELEASE': self.release,
            'PRODUCT_BRANCH': self.product_branch,
            'VERSION': self.version,
            'BLD_NUM': self.build_num,
            'PROD_NAME': self.prod_name,
            'PRODUCT_PATH': self.product_path,
            'MANIFEST': str(self.manifest),
            'PARENT': self.parent,
            'TYPE': self.type,
            'BUILD_JOB': self.build_job,
            'PLATFORMS': self.platforms,
            'GO_VERSION': self.go_version,
            'FORCE': self.force
        }

        with open(self.output_files['build-properties.json'], 'w') as fh:
            json.dump(properties, fh, indent=2, separators=(',', ': '))

        with open(self.output_files['build.properties'], 'w') as fh:
            plats = ' '.join(self.platforms)
            fh.write(f'PRODUCT={self.product}\n'
                     f'RELEASE={self.release}\n'
                     f'PRODUCT_BRANCH={self.product_branch}\n'
                     f'VERSION={self.version}\n'
                     f'BLD_NUM={self.build_num}\n'
                     f'PROD_NAME={self.prod_name}\n'
                     f'PRODUCT_PATH={self.product_path}\n'
                     f'MANIFEST={self.manifest}\n'
                     f'PARENT={self.parent}\n'
                     f'TYPE={self.type}\n'
                     f'BUILD_JOB={self.build_job}\n'
                     f'PLATFORMS={plats}\n'
                     f'GO_VERSION={self.go_version}\n'
                     f'FORCE={self.force}\n')

    def create_tarball(self):
        """
        Create the source tarball from the repo sync and generated
        files (new manifest and CHANGELOG).  Avoid copying the .repo
        information, and only copy the .git directory if specified.
        """

        tarball_filename = self.output_files['source.tar']
        targz_filename = self.output_files['source.tar.gz']

        print(f'Creating {tarball_filename}')
        product_dir = pathlib.Path(self.product_path)

        with pushd(product_dir):
            with tarfile.open(tarball_filename, 'w') as tar_fh:
                for root, dirs, files in os.walk('.'):
                    for name in files:
                        tar_fh.add(os.path.join(root, name)[2:])
                    for name in dirs:
                        if name == '.repo' or name == '.git':
                            dirs.remove(name)
                        else:
                            tar_fh.add(os.path.join(root, name)[2:],
                                       recursive=False)

            if self.manifest_config.get('keep_git', False):
                print(f'Adding Git files to {tarball_filename}')
                # When keeping git files, need to dereference symlinks
                # so that the resulting .git directories work on Windows.
                # Because of this, we don't save the .repo directory
                # also, as that would double the size of the tarball
                # since mostly .repo just contains git dirs.
                with tarfile.open(tarball_filename, "a",
                                  dereference=True) as tar:
                    for root, dirs, files in os.walk('.', followlinks=True):
                        for name in dirs:
                            if name == '.repo':
                                dirs.remove(name)
                            elif name == '.git':
                                tar.add(os.path.join(root, name)[2:],
                                        recursive=False)
                        if '/.git' in root:
                            for name in files:
                                # Git (or repo) sometimes creates broken
                                # symlinks, like "shallow", and Python's
                                # tarfile module chokes on those
                                if os.path.exists(os.path.join(root, name)):
                                    tar.add(os.path.join(root, name)[2:],
                                            recursive=False)

        print(f'Compressing {tarball_filename}')

        with open(tarball_filename, 'rb') as f_in, \
                gzip.open(targz_filename, 'wb') as f_out:
            shutil.copyfileobj(f_in, f_out)

        os.unlink(tarball_filename)

    def generate_final_files(self):
        """
        Generate the new files needed, which are:
          - new build manifest
          - properties files (JSON and INI-style)
          - source tarball (which includes the manifest)
        """

        self.copy_build_manifest()
        self.create_properties_files()
        self.create_tarball()

    def create_manifest(self):
        """
        The orchestration method to handle the full program flow
        from a high-level overview.  Summary:

          - Prepare for various key files, removing any old ones
          - Determine the product information from the config files
          - Setup manifest repository and determine build information
            from it
          - If there are submodules, ensure they're updated
          - Set the relevant and necessary paramaters (e.g. version)
          - Do a repo sync based on the given manifest
          - Update the build-manifests repository and determine
            the next build number to use
          - Generate the CHANGELOG and update the build manifest
            annotations
          - Push the generated manifest to build-manifests, if
            pushing is requested
          - Generate the new build manifest, properties files, and
            source tarball
        """

        self.prepare_files()
        self.do_manifest_stuff()

        module_projects = self.manifest_config.get('module_projects')
        if module_projects is not None:
            self.update_submodules(module_projects)

        self.set_relevant_parameters()
        self.set_build_parameters()
        self.perform_repo_sync()
        self.update_bm_repo_and_get_build_num()

        with pushd(self.product_path):
            self.generate_changelog()
            commit_msg = self.update_build_manifest_annotations()

        self.push_manifest(commit_msg)
        self.generate_final_files()


def parse_args():
    """Parse and return command line arguments"""

    parser = argparse.ArgumentParser(
        description='Create new build manifest from input manifest'
    )
    parser.add_argument('--manifest-project', '-p',
                        default='git://github.com/couchbase/manifest',
                        help='Alternate Git URL for manifest repository')
    parser.add_argument('--push-manifest-project',
                        help='Git repository to push updated input manifests '
                             '(defaults to same as --manifest-project)')
    parser.add_argument('--build-manifests-org', default='couchbase',
                        help='Alternate GitHub organization for '
                             'build-manifests')
    parser.add_argument('--force', '-f', action='store_true',
                        help='Produce new build manifest even if there '
                             'are no repo changes')
    parser.add_argument('--no-push', action='store_true',
                        help='Do not push final build manifest')
    parser.add_argument('manifest', help='Path to input manifest')

    args = parser.parse_args()
    if args.push_manifest_project is None:
        args.push_manifest_project = args.manifest_project

    return args


def main():
    """Initialize manifest builder object and trigger the build"""

    # Make sure log output comes out in the right order
    os.environ['PYTHONUNBUFFERED'] = "1"

    manifest_builder = ManifestBuilder(parse_args())
    manifest_builder.create_manifest()


if __name__ == '__main__':
    main()
