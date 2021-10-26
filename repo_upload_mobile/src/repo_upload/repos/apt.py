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
import signal
import string
import subprocess
import time

from collections import OrderedDict
from pkg_resources import resource_filename
from pathlib import Path

import requests

from .base import RepositoryBase, Status
from .logger import logger

class AptRepository(RepositoryBase):
    """
    Manages creating and uploading APT package repositories
    """

    def __init__(self, args, common_info, config_datadir, config_datafile, products, product_line):
        """
        Load in APT-specific data from JSON file and initialize various
        common parameters and generate the Aptly configuration file
        """

        super().__init__(args, common_info, config_datadir, config_datafile, products, product_line)

        data = self.load_config('apt.json')

        self.os_versions = data['os_versions']
        self.distro_info = data['distro_info']
        self.repo_dir = self.local_repo_root / self.edition / 'deb'

        self.create_aptly_conf()
        self.aptly_api = None

    @staticmethod
    def handler(_signum, _frame):
        """Timeout handler for Aptly API server"""

        logger.fatal('Unable to start Aptly API server in specified time')
        exit(1)

    def start_aptly_api_server(self):
        """
        Start the Aptly API server; used to communicate to Aptly via
        HTTP requests
        """

        self.aptly_api = subprocess.Popen(
            ['aptly', 'api', 'serve'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )

        # Give the server time to start; if 10 seconds is reached, abort
        signal.signal(signal.SIGALRM, self.handler)
        signal.alarm(10)

        while True:
            try:
                req = requests.get('http://localhost:8080/api/version')
            except requests.exceptions.ConnectionError:
                # Server not started yet, wait a moment then try again
                time.sleep(.5)
                continue

            # Once server is up, continue on
            if req.status_code == 200:
                break

        # Server now up, safe to continue
        signal.alarm(0)

    def stop_aptly_api_server(self):
        """
        Stop the Aptly API server
        """

        if self.aptly_api is not None:
            self.aptly_api.terminate()

    @contextlib.contextmanager
    def handle_repo_server(self):
        """
        Simple context manager to handle the Aptly API server;
        ensure the stop method runs regardless of success of
        the application
        """

        try:
            self.start_aptly_api_server()
            yield
        finally:
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

    def write_source_file(self, os_version, edition):
        """
        Create the sources.list file used for a given version
        """

        src_file_dir = (self.local_repo_root /
                        'sources.list.d' / os_version / edition)
        src_file = str(src_file_dir) + "/" +  self.product_line + '.list'
        distro = self.os_versions[os_version]['distro']
        sec_url = self.distro_info[distro]['security_url']
        sec_path = self.distro_info[distro]['security_path'].format(os_version)

        os.makedirs(src_file_dir, exist_ok=True)

        with open(src_file, 'w') as fh:
            tmpl_file = os.path.join(
                resource_filename('repo_upload', 'conf'),
                'sources.list.tmpl'
            )
            try:
                src_tmpl = string.Template(open(tmpl_file).read())
            except FileNotFoundError:
                logger.fatal(f'File not found: {tmpl_file}')
                exit(1)
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

        logger.debug(
            f'Ready to seed Debian repositories at {self.local_repo_root}')

    def write_distro_file_header(self):
        """
        Creates [product_line]/[edition]/deb/conf/distributions file
        populated with header text
        """

        conf_dir = self.repo_dir / 'conf'
        os.makedirs(conf_dir, exist_ok=True)
        distro_file = conf_dir / 'distributions'

        logger.debug(f'Writing {str(distro_file)}...')

        with open(distro_file, 'w') as fh:
            fh.write(f'# {self.curr_date}\n#\n')
            fh.write(f'# Data to be used in the various repositories\n')
            fh.write(f'# Can be found in the various Release files\n')
            fh.write(f'# See https://wiki.debian.org/DebianRepository/'
                     f'Format#A.22Release.22_files\n# for more information\n')

    def write_distro_file_section(self, distro, edition, platforms):
        """
        Adds distro details to couchbase-lite/[edition]/deb/conf/distributions
        """
        conf_dir = self.repo_dir / 'conf'
        distro_file = conf_dir / 'distributions'
        tmpl_file = os.path.join(
            resource_filename('repo_upload', 'conf'),
            'distributions.tmpl'
        )

        logger.debug(
            f'Writing {str(distro_file)} section: {distro} / {edition}...')

        dist_tmpl = string.Template(open(tmpl_file).read())
        data = {
            'distro': distro,
            'edition_name': edition,
            'repo_class': 'main',
            'key': self.key,
            'product_line': self.product_line,
            'platforms': platforms,
            'version': self.os_versions[distro]['version'],
        }

        with open(distro_file, 'a') as fh:
            fh.write(dist_tmpl.substitute(data))

    def seed_local_repo(self, distro, edition, platforms):
        """
        Create a local repo if it does not exist.
        And add distribution/component to the repo
        """

        self.write_distro_file_section(distro, edition, platforms)

        headers = {'Content-Type': 'application/json'}
        payload = {
            'Name': distro,
            'DefaultDistribution': distro,
            'DefaultComponent': f'{distro}/main',
        }

        # Create repo, only if repo deos not exist (code != 400)
        req = requests.get('http://localhost:8080/api/repos/{distro}')
        if req.status_code != 400:
            req = requests.post(
                'http://localhost:8080/api/repos', headers=headers,
                data=json.dumps(payload)
            )
            #exit if repo creation fails
            if req.status_code != 201 and not json.loads(req.content)['error'].startswith('local repo with name'):
                logger.fatal(f'Unable to create Debian repository {distro}')
                exit(1)
        else:
            logger.debug(f'Skip creating {distro} repo since it already exists.')

    def seed_local_repos(self):
        """
        Create the local repositories to allow packages to be imported
        into them
        """

        logger.debug(f'Creating local {self.edition} Debian repositories '
                     f'at {self.repo_dir}...')

        self.write_distro_file_header()

        for distro in self.os_versions:
            self.seed_local_repo(distro, self.edition, self.os_versions[distro]["platforms"])

        logger.debug(
            f'Debian repositories ready for import at {self.local_repo_root}'
        )

    def get_s3_path(self, os_version):
        """
        Determine the path on S3 to the current repository
        """

        return os.path.join(self.s3_package_base, self.edition, 'deb/pool', os_version, 'main/c/', self.product_line)

    def import_packages(self):
        """
        Import all available versions of the packages for each
        of the OS versions, ignoring any 'missing' releases for
        a given OS version
        """

        if not self.pkg_dir.exists():
            os.makedirs(self.pkg_dir)

        repo_dir = self.repo_dir
        logger.debug(f'Importing into local {self.edition} repository '
                     f'at {repo_dir}')

        for release in self.supported_releases.get_releases():
            version, status = release

            # If aren't doing a staging run and we have
            # a development version, skip it
            if not self.staging and status == Status.DEVELOPMENT:
                continue

            for product in self.product_list:
                for distro in self.os_versions:
                    existing_pkgs = []
                    #Get all existing packages with {product} in name from repo.
                    #Contruct expected package names from params, compare against existing packages.
                    #Only fetch the package if it is not found in the repo.
                    req = requests.get(f'http://localhost:8080/api/repos/{distro}/packages?q={product}&format=details')
                    for p in req.json():
                        existing_pkgs.append((p['Filename']))
                    for platform in self.os_versions[distro]["platforms"].split(" "):
                        pkg_name = (f'{product}-{self.edition}_{version}-'
                            f'{self.os_versions[distro]["full"]}_{platform}.deb')
                        if pkg_name in existing_pkgs:
                            logger.debug(
                                f'{pkg_name} is already in repo {distro}, skip import')
                        elif self.fetch_package(pkg_name, release, distro):
                            logger.debug(
                                f'Uploading file {self.pkg_dir / pkg_name} to aptly upload area...')
                            files = {'file': open(self.pkg_dir / pkg_name, 'rb')}
                            req = requests.post(
                                f'http://localhost:8080/api/files/{self.pkg_dir}',
                                files=files
                            )

                            if req.status_code != 200:
                                logger.fatal(
                                    f'Failed to upload file {pkg_name} to aptly '
                                    f'upload area'
                                )
                                exit(1)

                            logger.debug(f'Adding file {pkg_name} to Debian repository '
                                f'{distro}')
                            req = requests.post(
                                f'http://localhost:8080/api/repos/{distro}/'
                                f'file/{self.pkg_dir}/{pkg_name}'
                            )

                            if req.status_code != 200:
                                logger.fatal(
                                    f'Failed to add file {pkg_name} to Debian repository {distro}: {req.text}'
                                )
                                exit(1)

    def finalize_local_repos(self):
        """
        Publish the local repositories and moved the new published
        directories into the top level of the repository area, clearing
        out unneeded directories in preparation for the upload to S3
        """
        for distro in self.os_versions:
            sources = [{'Component': f'{distro}/main', 'Name': distro}]
            payload = {
                'SourceKind': 'local',
                'Sources': sources,
                'Architectures': self.os_versions[distro]["platforms"].split(" "),
                'Distribution': distro,
            }
            headers = {'Content-Type': 'application/json'}

            logger.debug(f'    Publishing local Debian repository {distro}...')

            req = requests.post(
                f'http://localhost:8080/api/publish',
                headers=headers, data=json.dumps(payload)
            )

            if req.status_code != 201:
                logger.fatal(
                    f'Unable to publish local Debian repository {distro}: {req.text}')
                exit(1)

        public_repo_dir = self.repo_dir / 'public'
        public_repo_dists_dir = public_repo_dir / 'dists'
        public_repo_pool_dir = public_repo_dir / 'pool'

        repo_conf_dir = self.repo_dir / 'conf'
        repo_db_dir = self.repo_dir / 'db'
        repo_pool_dir = self.repo_dir / 'pool'

        logger.debug(
            f'Moving published Debian repositories into local repository area at {self.repo_dir}...')

        for local_repo_dir in [repo_conf_dir, repo_db_dir, repo_pool_dir, self.repo_dir / 'dists']:
            try:
                shutil.rmtree(local_repo_dir)
            except FileNotFoundError as e:
                pass

        public_repo_dists_dir.rename(self.repo_dir / 'dists')
        public_repo_pool_dir.rename(repo_pool_dir)
        public_repo_dir.rmdir()
        logger.debug(
            f'Published local Debian repositories ready at {self.repo_dir}')

    def upload_local_repos(self):
        """
        Upload the necessary directories from the local repositories
        into their desired locations on S3
        """

        logger.info(
            f'Uploading to s3: {self.repo_dir} {os.path.join(self.edition, "deb")}')
        self.s3_upload(self.repo_dir, os.path.join(self.edition, 'deb'))

        for meta_dir in ['keys', 'sources.list.d']:
            base_dir = self.local_repo_root / meta_dir

            logger.info(f'Uploading to s3: {base_dir} {meta_dir}')
            self.s3_upload(base_dir, meta_dir)

    def update_repository(self):
        """
        Handle all the necessary steps to update the repositories
        on S3; currently just a call to the abstract base class'
        method (future customization may be needed)
        """

        super().update_repository()
