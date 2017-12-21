"""
Handles the APT package repository process

Uses aptly to create and publish the repositories, along with its
API server that helps to avoid needing to call out to external
commands for the various steps
"""

import contextlib
import json
import os
import shutil
import string
import subprocess

from collections import OrderedDict
from pkg_resources import resource_filename
from pathlib import Path

import requests

from repo_upload.repos.base import RepositoryBase


class AptRepository(RepositoryBase):
    """
    Manages creating and uploading APT package repositories
    """

    def __init__(self, args, common_info):
        """
        Load in APT-specific data from JSON file and initialize various
        common parameters and generate the Aptly configuration file
        """

        super().__init__(args, common_info)

        data = self.load_config('apt.json')

        self.os_versions = data['os_versions']
        self.distro_info = data['distro_info']

        self.create_aptly_conf()
        self.aptly_api = None

    def start_aptly_api_server(self):
        """
        Start the Aptly API server; used to communicate to Aptly via
        HTTP requests
        """

        self.aptly_api = subprocess.Popen(
            ['aptly', 'api', 'serve'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )

    def stop_aptly_api_server(self):
        """
        Stop the Aptly API server
        """

        self.aptly_api.terminate()

    @contextlib.contextmanager
    def handle_repo_server(self):
        """
        Simple context manager to handle the Aptly API server
        """

        self.start_aptly_api_server()
        yield
        self.stop_aptly_api_server()

    def create_aptly_conf(self):
        """
        Create the Aptly configuration file; used to control how
        Aptly handles and locates the local repositories
        """

        conf = OrderedDict({
            "rootDir": f"{self.repo_dir}",
            "downloadConcurrency": 4,
            "downloadSpeedLimit": 0,
            "architectures": [],
            "dependencyFollowSuggests": False,
            "dependencyFollowRecommends": False,
            "dependencyFollowAllVariants": False,
            "dependencyFollowSource": False,
            "dependencyVerboseResolve": False,
            "gpgDisableSign": False,
            "gpgDisableVerify": False,
            "gpgProvider": "gpg",
            "downloadSourcePackages": False,
            "skipLegacyPool": True,
            "ppaDistributorID": "ubuntu",
            "ppaCodename": "",
            "skipContentsPublishing": False,
            "FileSystemPublishEndpoints": {},
            "S3PublishEndpoints": {},
            "SwiftPublishEndpoints": {}
        })
        conf_file = Path.home() / '.aptly.conf'

        with open(conf_file, 'w') as fh:
            json.dump(conf, fh, indent=2, separators=(',', ': '))

    def write_gpg_keys(self):
        """
        Write the supplied GPG file out to the local repository area
        """

        gpg_keys_dir = self.local_repo_root / 'keys'
        os.makedirs(gpg_keys_dir, exist_ok=True)
        shutil.copy(self.gpg_file, str(gpg_keys_dir.resolve()))

    def write_source_file(self, os_version, edition):
        """
        Create the sources.list file used for a given version
        """

        src_file_dir = (
            self.local_repo_root / 'sources.list.d' / os_version / edition
        )
        src_file = src_file_dir / 'couchbase-server.list'
        distro = self.os_versions[os_version]['distro']
        sec_url = self.distro_info[distro]['security_url']
        sec_path = \
            self.distro_info[distro]['security_path'].format(os_version)

        os.makedirs(src_file_dir, exist_ok=True)

        with open(src_file, 'w') as fh:
            tmpl_file = os.path.join(
                resource_filename('repo_upload', 'conf'),
                'sources.list.tmpl'
            )
            src_tmpl = string.Template(open(tmpl_file).read())
            data = {
                'curr_date': self.curr_date,
                'edition': edition,
                'gpg_file': self.gpg_file,
                'http_pkg_root': self.http_package_root,
                'os_version': os_version,
                'sec_path': sec_path,
                'sec_url': sec_url,
            }
            fh.write(src_tmpl.substitute(data))

    def write_sources(self):
        """
        For each edition and OS version combination, write the necessary
        source file
        """

        for edition in self.editions:
            for os_version in self.os_versions:
                self.write_source_file(os_version, edition)

    def prepare_local_repos(self):
        """
        Prepare for the local repositories by creating the GPG key file
        and the sources files for all the supported OS versions
        """

        # TODO: Delete local repo tree if exists and desired

        self.write_gpg_keys()
        self.write_sources()

        print(
            f'Ready to seed Debian repositories at {self.local_repo_root}'
        )

    def seed_local_repos(self):
        """
        Create the local repositories to allow packages to be imported
        into them
        """

        print(f'Creating local {self.edition} Debian repositories '
              f'at {self.repo_dir}...')

        conf_dir = self.repo_dir / 'conf'
        os.makedirs(conf_dir, exist_ok=True)
        distro_file = conf_dir / 'distributions'

        print(f'Writing {str(distro_file)}...')

        with open(distro_file, 'w') as fh:
            fh.write(f'# {self.curr_date}\n#\n')
            fh.write(f'# Data to be used in the various repositories\n')
            fh.write(f'# Can be found in the various Release files\n')
            fh.write(f'# See https://wiki.debian.org/DebianRepository/'
                     f'Format#A.22Release.22_files\n# for more information\n')

            for distro in self.os_versions:
                tmpl_file = os.path.join(
                    resource_filename('repo_upload', 'conf'),
                    'distributions.tmpl'
                )
                dist_tmpl = string.Template(open(tmpl_file).read())
                data = {
                    'distro': distro,
                    'edition_name': self.edition_name,
                    'key': self.key,
                    'version': self.os_versions[distro]['version'],
                }
                fh.write(dist_tmpl.substitute(data))

                payload = {
                    'Name': distro,
                    'DefaultDistribution': distro,
                    'DefaultComponent': f'{distro}/main',
                }
                headers = {'Content-Type': 'application/json'}

                req = requests.post(
                    'http://localhost:8080/api/repos', headers=headers,
                    data=json.dumps(payload)
                )

                if req.status_code != 201:
                    raise RuntimeError(
                        f'Unable to create Debian repository {distro}'
                    )

        print(
            f'Debian repositories ready for import at {self.local_repo_root}'
        )

    def get_s3_path(self, os_version):
        """
        Determine the path on S3 to the current repository
        """

        return (f'{self.s3_package_base}/{self.edition}/deb/'
                f'pool/{os_version}/main/c/couchbase-server')

    def import_packages(self):
        """
        Import all available versions of the packages for each
        of the OS versions, ignoring any 'missing' releases for
        a given OS version
        """

        if not self.pkg_dir.exists():
            os.makedirs(self.pkg_dir)

        print(f'Importing into local {self.edition} repository '
              f'at {self.repo_dir}')

        for release in self.supported_releases.get_releases():
            version, in_dev = release

            # If aren't doing a staging run and we have
            # a development version, skip it
            if not self.staging and in_dev:
                continue

            for distro in self.os_versions:
                pkg_name = (f'couchbase-server-{self.edition}_{version}-'
                            f'{self.os_versions[distro]["full"]}_amd64.deb')

                if self.fetch_package(pkg_name, release, distro):
                    print(
                        f'Uploading file {pkg_name} to aptly upload area...'
                    )
                    files = {'file': open(self.pkg_dir / pkg_name, 'rb')}
                    req = requests.post(
                        f'http://localhost:8080/api/files/{self.pkg_dir}',
                        files=files
                    )

                    if req.status_code != 200:
                        raise RuntimeError(
                            f'Failed to upload file {pkg_name} to aptly '
                            f'upload area'
                        )

                    print(f'Adding file {pkg_name} to Debian repository '
                          f'{distro}')
                    req = requests.post(
                        f'http://localhost:8080/api/repos/{distro}/'
                        f'file/{self.pkg_dir}/{pkg_name}'
                    )

                    if req.status_code != 200:
                        raise RuntimeError(
                            f'Failed to add file {pkg_name} to Debian '
                            f'repository {distro}'
                        )

    def finalize_local_repos(self):
        """
        Publish the local repositories and moved the new published
        directories into the top level of the repository area, clearing
        out unneeded directories in preparation for the upload to S3
        """

        public_repo_dir = self.repo_dir / 'public'
        public_repo_dists_dir = public_repo_dir / 'dists'
        public_repo_pool_dir = public_repo_dir / 'pool'

        repo_conf_dir = self.repo_dir / 'conf'
        repo_db_dir = self.repo_dir / 'db'
        repo_pool_dir = self.repo_dir / 'pool'

        print(f'Publishing into local Debian repositories at '
              f'{public_repo_dir}...')

        for distro in self.os_versions:
            payload = {
                'SourceKind': 'local',
                'Sources': [{'Component': f'{distro}/main', 'Name': distro}],
                'Architectures': ['amd64'],
                'Distribution': distro,
            }
            headers = {'Content-Type': 'application/json'}

            print(f'    Publishing local Debian repository {distro}...')

            req = requests.post(
                f'http://localhost:8080/api/publish',
                headers=headers, data=json.dumps(payload)
            )

            if req.status_code != 201:
                raise RuntimeError(
                    f'Unable to publish local Debian repository {distro}'
                )

        print(f'Moving published Debian repositories into local repository '
              f'area at {self.repo_dir}...')

        for repo_dir in [repo_conf_dir, repo_db_dir, repo_pool_dir]:
            shutil.rmtree(repo_dir)

        public_repo_dists_dir.rename(self.repo_dir / 'dists')
        public_repo_pool_dir.rename(repo_pool_dir)
        public_repo_dir.rmdir()

        print(f'Published local Debian repositories ready at {self.repo_dir}')

    def upload_local_repos(self):
        """
        Upload the necessary directories from the local repositories
        into their desired locations on S3
        """

        self.s3_upload(self.repo_dir, os.path.join(self.edition, 'deb'))

        # NOTE: Both community and enterprise sources.list files are
        # copied; maybe not necessary?
        for meta_dir in ['keys', 'sources.list.d']:
            base_dir = self.local_repo_root / meta_dir

            self.s3_upload(base_dir, meta_dir)

    def update_repository(self):
        """
        Handle all the necessary steps to update the repositories
        on S3; currently just a call to the abstract base class'
        method (future customization may be needed)
        """

        super().update_repository()
