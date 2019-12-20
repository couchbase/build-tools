"""
A component part of build_from_manifest
"""

import logging
import os
import contextlib
import subprocess
import sys
import re

from Git import Git
from lxml import etree
from manifest_util import remember_cwd


class Manifest:
    """
    A class which consumes a source manifest, and walks the source tree
    to produce an output manifest containing any remotes or projects
    which were absent from the source

    Parameters
    ----------
    source_manifest : `str`
        Relative filename of source manifest
    """

    def __init__(self, source_manifest):
        self.tree = None
        self.remotes = {}
        self.projects = None
        self.manifest_data = None
        self.build_manifest = None
        self.default_revision = None
        self.source_manifest = source_manifest
        self.sha_re = re.compile(r"[a-f0-9]{40}")
        self.load_source_manifest()
        self.get_projects()
        self.get_metadata()

    def load_source_manifest(self):
        """ Loads source manifest from `self.source_manifest` """
        with open(self.source_manifest) as fh:
            self.manifest_data = etree.XML(fh.read().encode('utf-8'))
            self.tree = etree.ElementTree(self.manifest_data)
            self.root = self.tree.getroot()

    def get_default_revision(self):
        """ Acquires the default value for revision """
        for default in self.manifest_data.findall('default'):
            self.default_revision = default.get('revision')

    def get_remotes(self):
        """ Acquire Git remotes listed in manifest """
        remotes = dict()
        for remote in self.tree.findall('remote'):
            [name, url] = [remote.get('name'), remote.get('fetch')]
            # Skip incomplete/invalid remotes
            if None in [name, url]:
                continue
            remotes[url] = name
        self.remotes = remotes

    def get_projects(self):
        """ Acquire information for repositories in manifest """
        projects = dict()
        for project in self.tree.findall('project'):
            name = project.get('name')
            remote = project.get('remote')
            revision = project.get('revision')
            # Default path is the project's name
            path = project.get('path', name)
            # Skip incomplete/invalid projects
            if name is None:
                continue
            projects[path] = {
                'name': name,
                'remote': remote,
                'revision': revision,
                'path': path,
            }
        self.projects = projects

    def get_metadata(self):
        """
        Parses and extracts information for the remotes and projects,
        needed to retrieve the repository and gits to be updated

        Returns
        -------
        True on success
        """
        self.get_default_revision()
        self.get_remotes()
        self.get_projects()
        return True

    def get_maybe_missing_remote(self, url):
        """
        If URL is not a known remote URL, create a new <remote> element
        with a heuristically-generated "name".
        Whether it was known or not, return both the name and repo remote URL.
        """

        # Compute repo's idea of "remote URL" by chopping off the tailing
        # directory name, and give it a name based on the preceding directory
        # component and the URL scheme. We append the scheme so that we can't
        # accidentally collide with a <remote> element from the input manifest.
        parts = url.rsplit('/', 2)
        remote_url = f"{parts[0]}/{parts[1]}/"
        scheme = url.split(':')[0]
        remote_name = f"{parts[1]}-{scheme}"

        # Ensure we haven't already added this repo remote URL
        if remote_url in self.remotes:
            return [ self.remotes[remote_url], remote_url ]

        # Remember this generated remote name for next time
        logging.debug(f'Adding missing remote: {remote_name} -> {remote_url}')
        self.remotes[remote_url] = remote_name

        # Couchbase manifests use ssh://git@github.com/ rather than
        # https://github.com/, for the most part
        couch_url = remote_url.replace(
            'https://github.com/', 'ssh://git@github.com/'
        )

        # Add new <remote> element
        l = etree.Element(
            "remote",
            fetch=couch_url,
            name=remote_name
        )
        l.tail = "\n  "
        self.root.insert(0, l)

        return [ remote_name, remote_url ]

    def find_missing_projects(self, gits):
        """
        Identify and adds projects absent from source manifest

        Parameters
        ----------
        gits : `dict`, mandatory
            A dict of dicts, with key 'directory' and value:
            {
                SHA,
                directory,
                url
            }
        """
        first_project = self.root.find('./project')
        for directory, values in gits.items():
            if directory and directory not in self.projects:
                # This path is unknown - add a new project element.
                # First lookup / create the remote name.
                url = values['url']
                [remote_name, _] = self.get_maybe_missing_remote(url)
                project_name = os.path.basename(url)
                if project_name.endswith('.git'):
                    project_name = project_name[:-4]
                l = etree.Element(
                    "project",
                    name=project_name,
                    path=values['directory'],
                    remote=remote_name,
                    revision=values['SHA']
                )
                l.tail = "\n  "
                first_project.addprevious(l)
                self.projects[directory] = values
                logging.info(f"Added missing project: {directory}")

    def add_missing_remotes_and_projects(self, path):
        """ Walk project directory tree and identify missing projects """
        g = Git()
        g.walk_tree(path)
        self.find_missing_projects(g.gits)

    def save_build_manifest(self, filename):
        """ Write the XML tree back out to a file """
        logging.info("Writing build manifest")
        with open(filename, 'w') as fh:
            fh.write('<?xml version="1.0" encoding="UTF-8"?>\n')
            fh.write(etree.tostring(
                self.tree, encoding='unicode', pretty_print=True
            ))


if __name__ == '__main__':
    pass
