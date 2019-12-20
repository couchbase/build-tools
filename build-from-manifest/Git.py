import os
import re
import sys
import subprocess
import contextlib
import configparser
from manifest_util import remember_cwd


class Git:
    """
    A class which is used to capture git information
    """

    def __init__(self):
        self.gits = {}

    @staticmethod
    def checkout_branch(directory, branch):
        """
        Perform a "git checkout" of a specified branch in a given directory
        """

        with remember_cwd():
            os.chdir(directory)
            subprocess.check_call(
                ['git', 'checkout', branch],
                stdout=subprocess.PIPE
            )

    @staticmethod
    def update_submodules(directory):
        """
        Perform recursive git submodule update for given directory

        Parameters
        ----------
        directory : str
            Path to git repository
        """
        with remember_cwd():
            os.chdir(directory)
            subprocess.check_call(
                ['git', 'submodule', 'update', '--init', '--recursive'],
                stdout=subprocess.PIPE
            )

    @staticmethod
    def get_sha(directory):
        """
        Get SHA-1 for a git repository HEAD

        Parameters
        ----------
        directory : str
            Path to git repository

        Returns
        -------
        str
            SHA-1 of repository HEAD
        """
        with remember_cwd():
            os.chdir(directory)
            git_call = subprocess.Popen(['git', 'rev-parse', '--verify', 'HEAD'],
                                        stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT)
            stdout, _ = git_call.communicate()
            return stdout.decode('utf-8').strip()

    def walk_tree(self, start_node):
        """
        Traverses a directory tree retrieving information on .git subdirectories
        """
        with remember_cwd():
            os.chdir(start_node)
            for directory, dirnames, filenames in os.walk('.'):
                dirnames[:] = [d for d in dirnames if d != '.repo']
                if('.git' in filenames + dirnames):
                    self.add_git(directory[2:])

    @staticmethod
    def get_remote_url():
        """
        Get remote url for current workdir repo

        Returns `str`
        """
        git_call = subprocess.Popen(['git', 'remote', '-v'],
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT)
        # TODO: handle stderr
        stdout, _ = git_call.communicate()
        remote_lines = stdout.decode('utf-8').strip().split('\n')
        # Track whether any remote has already been added
        added = False
        for entry in remote_lines:
            parts = re.split('\t| ', entry)
            # push entry is ignored
            if(parts[2][1:-1:] == 'fetch'):
                if added:
                    raise RuntimeError(
                        f'Multiple remotes identified including {parts[1]}, please investigate')
                else:
                    url = parts[1]
                    added = True
        return url

    def add_git(self, directory):
        """
        Adds a SHA/directory/remote/url dict to self.gits for a given git directory

        Parameters
        ----------
        directory : str
            Path to git directory
        """
        with remember_cwd():
            os.chdir(directory)
            self.gits[directory] = {
                'SHA': self.get_sha(os.getcwd()),
                'directory': directory,
                'url': Git.get_remote_url()
            }
