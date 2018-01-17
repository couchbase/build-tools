"""
Handles the Yum package repository process

Uses yumrepos to create and publish the repositories, along with
its API server that helps to avoid needing to call out to external
commands for the various steps
"""

import contextlib
import os
import shutil
import string
import subprocess

from pkg_resources import resource_filename

import pexpect

from repo_upload.repos.base import RepositoryBase


class YumRepository(RepositoryBase):
    """
    Manages creating and uploading APT package repositories
    """

    def __init__(self, args, common_info):
        """
        Load in Yum-specific data from JSON file and initialize various
        common parameters
        """

        super().__init__(args, common_info)

        data = self.load_config('yum.json')

        self.os_versions = data['os_versions']

    def start_yumapi_server(self):
        """
        Start the Yum API server; used to manage Yum repositories via
        HTTP requests
        """

        return  # No workable Yum API server currently

    def stop_yumapi_server(self):
        """
        Stop the Yum API server
        """

        return  # No workable Yum API server currently

    @contextlib.contextmanager
    def handle_repo_server(self):
        """
        Simple context manager to handle the Yum API server
        """

        self.start_yumapi_server()
        yield
        self.stop_yumapi_server()

    def write_source_file(self, os_version, edition):
        """
        Create the Yum .repo file used for a given version
        """

        src_file_dir = (
            self.local_repo_root / 'yum.repos.d' / os_version / edition
        )
        src_file = src_file_dir / 'couchbase-server.repo'

        os.makedirs(src_file_dir, exist_ok=True)

        with open(src_file, 'w') as fh:
            tmpl_file = os.path.join(
                resource_filename('repo_upload', 'conf'),
                'yum.repo.tmpl'
            )
            src_tmpl = string.Template(open(tmpl_file).read())
            data = {
                'curr_date': self.curr_date,
                'edition': edition,
                'gpg_file': self.gpg_file,
                'http_pkg_root': self.http_package_root,
            }
            fh.write(src_tmpl.substitute(data))

    def write_sources(self):
        """
        For each edition and OS version combination, write the necessary
        Yum .repo file
        """

        for edition in self.editions:
            for os_version in self.os_versions:
                self.write_source_file(os_version, edition)

    def prepare_local_repos(self):
        """
        Prepare for the local repositories by creating the GPG key file
        and the Yum .repo files for all the supported OS versions
        """

        # TODO: Delete local repo tree if exists and desired

        self.write_gpg_keys()
        self.write_sources()

        print(
            f'Ready to seed RedHat repositories at {self.local_repo_root}'
        )

    def seed_local_repos(self):
        """
        Create the local repositories to allow packages to be imported
        into them
        """

        print(f'Creating local {self.edition} RedHat repositories '
              f'at {self.repo_dir}...')

        for os_version in self.os_versions:
            conf_dir = self.repo_dir / os_version / 'x86_64'
            os.makedirs(conf_dir, exist_ok=True)

            proc = subprocess.run(
                ['createrepo', conf_dir],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )

            if proc.returncode:
                raise RuntimeError(
                    f'Unable to create RedHat repository {os_version}/x86_64'
                )

        print(
            f'RedHat repositories ready for import at {self.local_repo_root}'
        )

    def get_s3_path(self, os_version):
        """
        Determine the path on S3 to the current repository
        """

        return (f'{self.s3_package_base}/{self.edition}/rpm/'
                f'{os_version}/x86_64')

    @staticmethod
    def is_signed(pkg):
        """
        Check to see if an RPM package is signed
        """

        proc = subprocess.run(
            ['rpm', '-qpi', pkg],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        output = proc.stdout.decode().split('\n')
        signed = None

        for line in output:
            if line.startswith('Signature'):
                signed = line.split(':', 1)[1].strip()
                break

        return True if signed != '(none)' else False

    def sign_rpm(self, pkg_name):
        """
        Sign RPM package: uses 'rpm --resign' with a few defines
        to accomplish this, and requires pexpect (interactive)
        """

        cmd = 'rpm'
        args = ['--resign', '-D', '_signature gpg',
                '-D', f'_gpg_name {self.rpm_key}',
                str(self.pkg_dir / pkg_name)]

        print(f'    Signing {self.pkg_dir / pkg_name}...')
        try:
            child = pexpect.spawn(cmd, args)
            child.expect('Enter pass phrase: ')
            child.sendline('')
            child.expect(pexpect.EOF)
        except pexpect.EOF:
            raise RuntimeError(
                f'Unable to sign package {self.pkg_dir / pkg_name}: '
                f'{child.before}'
            )

    def import_packages(self):
        """
        Import all available versions of the packages for each
        of the OS versions, ignoring any 'missing' releases for
        a given OS version
        """

        if not self.pkg_dir.exists():
            os.makedirs(self.pkg_dir)

        print(f'Importing into local {self.edition} repositories '
              f'at {self.repo_dir}')

        for release in self.supported_releases.get_releases():
            version, in_dev = release

            # If aren't doing a staging run and we have
            # a development version, skip it
            if not self.staging and in_dev:
                continue

            for os_version in self.os_versions:
                pkg_name = (f'couchbase-server-{self.edition}-{version}-'
                            f'centos{os_version}.x86_64.rpm')

                if self.fetch_package(pkg_name, release, os_version):
                    print(
                        f'    Copying file {pkg_name} to RedHat repository '
                        f'{os_version}/x86_64...'
                    )
                    pkg_basepath = self.repo_dir / os_version / 'x86_64'
                    shutil.copy(self.pkg_dir / pkg_name, pkg_basepath)

                    if not self.is_signed(pkg_basepath / pkg_name):
                        self.sign_rpm(pkg_basepath / pkg_name)

        print(f'RedHat repositories ready for signing')

    def finalize_local_repos(self):
        """
        Sign the local repositories in preparation for the upload to S3
        """

        print(f'Signing local {self.edition} repositories at {self.repo_dir}')

        for os_version in self.os_versions:
            conf_dir = self.repo_dir / os_version / 'x86_64'
            repomd_file = conf_dir / 'repodata' / 'repomd.xml'
            signed_repomd_file = f'{repomd_file}.asc'

            proc = subprocess.run(
                ['createrepo', '--update', conf_dir],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )

            if proc.returncode:
                raise RuntimeError(
                    f'Unable to update RedHat repository {os_version}/x86_64'
                )

            signed_data = self.gpg.sign_file(
                open(repomd_file, 'rb'), keyid=self.rpm_key, detach=True,
                output=signed_repomd_file
            )

            if signed_data.status != 'signature created':
                raise RuntimeError(
                    f'    Unable to sign local {self.edition} repository '
                    f'at {conf_dir}'
                )

        print(f'   Done signing local {self.edition} repositories '
              f'at {self.repo_dir}')

    def upload_local_repos(self):
        """
        Upload the necessary directories from the local repositories
        into their desired locations on S3
        """

        self.s3_upload(self.repo_dir, os.path.join(self.edition, 'rpm'))

        for meta_dir in ['keys', 'yum.repos.d']:
            base_dir = self.local_repo_root / meta_dir

            self.s3_upload(base_dir, meta_dir)

    def update_repository(self):
        """
        Handle all the necessary steps to update the repositories
        on S3; currently just a call to the abstract base class'
        method (future customization may be needed)
        """

        super().update_repository()
