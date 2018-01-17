"""
Base abstract class for the various repository classes

Using abstract methods here to ensure new repository types are implemented
correctly, along with defining the general flow of the program here
"""

import abc
import hashlib
import json
import os
import shutil

from collections import namedtuple
from datetime import datetime
from pathlib import Path
from pkg_resources import resource_filename

import boto3
import botocore.exceptions
import gnupg
import requests


class Releases:
    """
    Simple class to maintain information about the current available
    and in-development release versions
    """

    def __init__(self, release_info, edition):
        """
        Generate list of namedtuples of all the versions for the given
        edition, each one containing the version and whether it's only
        for staging (in development) or not
        """

        self.releases = list()
        Release = namedtuple('Release', ['version', 'in_dev'])

        for version in release_info[edition]['released']:
            self.releases.append(Release(version=version, in_dev=False))

        for version in release_info[edition]['development']:
            self.releases.append(Release(version=version, in_dev=True))

    def get_releases(self):
        """
        Generator method to return unpacked information for each
        release namedtuple
        """

        for release in self.releases:
            yield release.version, release.in_dev


class RepositoryBase(metaclass=abc.ABCMeta):
    """
    Base abstract class for various repository classes
    """

    @abc.abstractmethod
    def __init__(self, edition, common_info):
        """
        Load in common data from JSON file and initialize various
        common parameters
        """

        data = self.load_config('base.json')

        self.editions = data['editions']
        self.edition = edition
        self.edition_name = f'{self.edition.capitalize()} Edition'
        self.staging = common_info.getboolean('staging')
        self.supported_releases = \
            Releases(data['supported_releases'], self.edition)

        self.local_repo_root = Path.home() / Path(common_info['repo_path'])
        self.s3 = boto3.resource('s3')
        self.s3_bucket = common_info['s3_bucket']
        self.s3_package_base = common_info['s3_base_path']
        self.s3_package_root = f's3://{self.s3_bucket}/{self.s3_package_base}'
        self.http_package_root = self.s3_package_root.replace('s3', 'http')
        self.releases_url = common_info['releases_url']
        self.gpg = gnupg.GPG()
        self.gpg_file = Path.home() / '.ssh' / common_info['gpg_file']
        self.gpg_keys = data['gpg_keys']
        self.pkg_dir = Path('packages')
        self.key = common_info['gpg_key']
        self.rpm_key = common_info['rpm_gpg_key']

        # The following emulates the 'date' shell command
        self.curr_date = \
            datetime.now().astimezone().strftime('%a %b %d %X %Z %Y')

    @staticmethod
    def load_config(filename):
        """
        Loads data from a JSON file, accessible as a dictionary
        """

        conf_file = os.path.join(
            resource_filename('repo_upload', 'conf'), filename
        )
        return json.load(open(conf_file))

    def import_gpg_keys(self):
        """
        Import the GPG keys needed for signing/publishing; only import
        keys that haven't yet been imported
        """

        current_keys = [k['keyid'][-8:] for k in self.gpg.list_keys(True)]

        for key in self.gpg_keys:
            key_id = key.split('.')[0]
            key_file = Path.home() / '.ssh' / key

            if key_id not in current_keys:
                result = self.gpg.import_keys(open(key_file, 'rb').read())

                if not result.count:
                    raise RuntimeError(f'Unable to import GPG key {key}')

    @staticmethod
    def get_md5(filename):
        """
        Generate the MD5 for a given file
        """

        hash_md5 = hashlib.md5()

        with open(filename, 'rb') as fh:
            for chunk in iter(lambda: fh.read(2 ** 20), b''):
                hash_md5.update(chunk)

        return hash_md5.hexdigest()

    def write_gpg_keys(self):
        """
        Write the supplied GPG file out to the local repository area
        """

        gpg_keys_dir = self.local_repo_root / 'keys'
        os.makedirs(gpg_keys_dir, exist_ok=True)
        shutil.copy(self.gpg_file, str(gpg_keys_dir.resolve()))

    @abc.abstractmethod
    def handle_repo_server(self):
        """
        Abstract method for managing the repository server
        (currently aptly's serve and yumrepos)
        """

        return

    @abc.abstractmethod
    def prepare_local_repos(self):
        """
        Abstract method for preparing the local repositories
        """

        return

    @abc.abstractmethod
    def seed_local_repos(self):
        """
        Abstract method for seeding the local repositories
        """

        return

    @abc.abstractmethod
    def get_s3_path(self, os_version):
        """
        Abstract method for acquiring the path on S3 for a file
        """

        return

    def s3_download_file(self, pkg_name, os_version):
        """
        Download a given package file from S3; return success or
        failure result
        """

        s3_path = f'{self.get_s3_path(os_version)}/{pkg_name}'

        print(f'    Retrieving {s3_path} from {self.s3_bucket}...')
        bucket = self.s3.Bucket(self.s3_bucket)

        try:
            bucket.download_file(s3_path, f'{str(self.pkg_dir)}/{pkg_name}')
        except botocore.exceptions.ClientError:
            print(f'    Unable to retrieve {s3_path} from {self.s3_bucket}')
            return False
        else:
            return True

    def lb_download_file(self, pkg_name, version):
        """
        Download a given package file from a given URL; return success
        or failure result
        """

        release_url = f'{self.releases_url}/{version}'
        if self.edition == 'community':
            release_url = f'{release_url}/ce'

        print(f'    Fetching {pkg_name} from {release_url}...')
        req = requests.get(f'{release_url}/{pkg_name}', stream=True)

        if req.status_code != 200:
            print(f'    Unable to download file {pkg_name} '
                  f'from {release_url}')
            return False

        with open(self.pkg_dir / pkg_name, 'wb') as fh:
            shutil.copyfileobj(req.raw, fh)

        return True

    def download_file(self, pkg_name, release, os_version):
        """
        Determine where to download a given package file from, and run
        the appropriate method to do so:
            - If not a development version, download from S3, falling
              back to local release mirror if not there
            - Otherwise attempt to download from local release mirror,
              returning success or failure
        """

        version, in_dev = release

        if not in_dev and self.s3_download_file(pkg_name, os_version):
            return True

        return self.lb_download_file(pkg_name, version)

    def fetch_package(self, pkg_name, release, os_version):
        """
        For a given package name and release and OS versiona, acquire
        the package from a generated URL but only if the package is not
        already in the local storage area
        """

        pkg = self.pkg_dir / pkg_name

        if not Path(pkg).exists():
            print(f'Attempting to fetch {pkg_name}')
            return self.download_file(pkg_name, release, os_version)
        else:
            print(f'Already have {pkg_name} locally, skipping...')
            return True

    @abc.abstractmethod
    def import_packages(self):
        """
        Abstract method for importing the Couchbase server packages
        into the local repositories
        """

        return

    @abc.abstractmethod
    def finalize_local_repos(self):
        """
        Abstract method for publishing or signing the local repositories
        """

        return

    def s3_upload_file(self, local_path, local_path_md5, s3_path):
        """

        """

        print(f'Searching {s3_path} in {self.s3_bucket}')
        obj = self.s3.Object(self.s3_bucket, s3_path)

        # If the loading of the object fails, it doesn't exist
        # and the file it's connected to needs to be uploaded;
        # otherwise check the MD5 sum stored in S3 for the file
        # to the one locally and only upload if it's different
        # (or the MD5 metadata is missing on S3 for that file)
        try:
            obj.load()
        except botocore.exceptions.ClientError:
            print(f'  Path {s3_path} not found, uploading...')
            obj.upload_file(
                local_path,
                ExtraArgs={'ACL': 'public-read',
                           'Metadata': {'md5': local_path_md5}}
            )
        else:
            print(f'  Path {s3_path} exists, checking MD5...')

            if ('md5' in obj.metadata and
                    obj.metadata['md5'] == local_path_md5):
                print(f'        It matches, skipping...')
            else:
                print(f'        It does not exist or differs, '
                      f'uploading...')
                obj.upload_file(
                    local_path,
                    ExtraArgs={'ACL': 'public-read',
                               'Metadata': {'md5': local_path_md5}}
                )

    def s3_upload(self, base_dir, rel_base_dir):
        """
        Upload a given directory tree to S3; uses additional metadata
        to maintain an MD5 for each file to prevent unnecessary uploads
        and speed up the synchronization
        """

        for root, dirs, files in os.walk(base_dir):
            for filename in files:
                local_path = os.path.join(root, filename)
                local_path_md5 = self.get_md5(local_path)
                relative_path = os.path.relpath(local_path, base_dir)
                s3_path = os.path.join(
                    self.s3_package_base, rel_base_dir, relative_path
                )

                self.s3_upload_file(local_path, local_path_md5, s3_path)

    @abc.abstractmethod
    def upload_local_repos(self):
        """
        Abstract method for uploading the local repositories to S3
        """

        return

    @abc.abstractmethod
    def update_repository(self):
        """
        Abstract method for handling the full process of creating
        and uploading the package repository; uses a context manager
        to handle the starting and stopping of the repository servers
        """

        with self.handle_repo_server():
            self.import_gpg_keys()
            self.prepare_local_repos()
            self.seed_local_repos()
            self.import_packages()
            self.finalize_local_repos()
            self.upload_local_repos()
