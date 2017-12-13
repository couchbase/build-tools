"""
Base abstract class for the various repository classes

Using abstract methods here to ensure new repository types are implemented
correctly, along with defining the general flow of the program here
"""

import abc
import hashlib
import subprocess

from pathlib import Path


class RepositoryBase(metaclass=abc.ABCMeta):
    """
    Base abstract class for various repository classes
    """

    gpg_keys = ['79CF7903.priv.gpg', 'CD406E62.priv.gpg', 'D9223EDA.priv.gpg']
    supported_releases = {
        'enterprise': ['4.0.0', '4.1.0', '4.1.1', '4.1.2', '4.5.0', '4.5.1',
                       '4.6.0', '4.6.1', '4.6.2', '4.6.3', '4.6.4', '5.0.0'],
        'community': ['4.0.0', '4.1.0', '4.1.1', '4.5.0', '4.5.1', '5.0.0'],
    }

    def import_gpg_keys(self):
        """
        Import the GPG keys needed for signing/publishing; only import
        keys that haven't yet been imported
        """

        for key in self.gpg_keys:
            proc = subprocess.run(
                ['gpg', '--list-keys', key.split('.')[0]],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )

            # A non-zero response means the key isn't there yet,
            # otherwise move to next key
            if not proc.returncode:
                continue

            key = str(Path.home() / '.ssh' / key)
            proc = subprocess.run(
                ['gpg', '--import', key],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )

            if proc.returncode:
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
