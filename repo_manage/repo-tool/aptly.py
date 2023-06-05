#!/usr/bin/env -S python3 -u

"""
Simple wrapper around the Aptly command-line client. It is given a path
to an aptly.conf, which it assumes is configured with "rootDir" pointing
to a reasonable location. It also assumes, for each "target" that is
used, there exists a FileSystemPublishEndpoint with that same name.
"""

import logging
import pathlib
import re
import requests
import subprocess
import sys
from collections import defaultdict
from typing import ClassVar, Dict, NamedTuple, Optional, Set
from util import render_template, run, run_output


class AptlyRepo(NamedTuple):
    target: str
    distro: str
    def __repr__(self) -> str:
        return f"{self.target}:{self.distro}"

class Aptly:

    def __init__(self, aptly_conf: Dict, targets: Dict) -> None:
        self.script_dir = pathlib.Path(__file__).resolve().parent
        self.config_file = self.script_dir / "aptly.conf"
        self.gpg_key = aptly_conf["gpg_key"]
        self.targets = targets

        context = aptly_conf.copy()
        context["targets"] = targets
        render_template(
            self.script_dir / "aptly.conf.j2",
            self.config_file,
            context
        )

        # Initialize set of repositories currently known to Aptly
        self.repos: Set[str] = set()
        self.repos.update(self.ask_aptly("repo list -raw").split())
        logging.debug(f"Found following aptly repos: {self.repos}")

        self.dirty_repos: Dict[AptlyRepo, Set[pathlib.Path]] = defaultdict(set)


    def ask_aptly(self, cmd: str) -> str:
        """
        Convenience function to run an 'aptly' command with the specified
        config file, returning any output
        """

        return run_output(f"aptly -config {self.config_file} {cmd}")


    def run_aptly(self, cmd: str) -> subprocess.CompletedProcess:
        """
        Convenience function to run an 'aptly' command with the specified
        config file
        """

        return run(f"aptly -config {self.config_file} {cmd}")


    def create_repo(self, repo: AptlyRepo) -> None:
        """
        Creates a new repository in aptly
        """

        logging.info(f"Initializing apt repo {repo}")
        self.run_aptly(
            f"repo create -distribution {repo.distro} -component main {repo}"
        )
        self.repos.update(self.ask_aptly("repo list -raw").split())


    def commit_package(self, repo: AptlyRepo, pkgfile: pathlib.Path) -> None:
        """
        Imports a package file into a specified Aptly repository,
        creating said repository if necessary
        """

        if not str(repo) in self.repos:
            self.create_repo(repo)

        logging.info(f"Importing {pkgfile} into apt repo {repo}")
        self.run_aptly(f"repo add {repo} {pkgfile}")


    def update_repo(self, repo: AptlyRepo) -> None:
        """
        Publishes specified repo to the local filesystem
        """

        # A repo will always be published locally to a root named after
        # the target, under a specified distro. See if there is an
        # existing publish set up for this already.
        fspath = f"filesystem:{repo.target}:."
        publish = f"{fspath} {repo.distro}"
        publishes: Set[str] = set()
        publishes.update(self.ask_aptly("publish list -raw").split('\n'))
        if not publish in publishes:
            logging.info(f"Publishing local apt repository {repo}")
            self.run_aptly(
                f"publish repo -acquire-by-hash "
                f"-gpg-key {self.gpg_key} "
                f"{repo} {fspath}"
            )
        else:
            logging.info(f"Updating local apt repository {repo}")
            self.run_aptly(
                f"publish update -skip-cleanup "
                f"-gpg-key {self.gpg_key} "
                f"{repo.distro} {fspath}"
            )


    def write_listfile(self, repo: AptlyRepo) -> None:
        """
        Saves a reference .list file for loading this repository from the
        current target
        """

        context = {
            "target": repo.target,
            "distro": repo.distro,
            "bucket": self.targets[repo.target]["s3"]["bucket"],
            "prefix": self.targets[repo.target]["s3"]["prefix"],
        }
        render_template(
            self.script_dir / "tmpl" / "debarchive.list.j2",
            pathlib.Path(
                self.targets[repo.target]["local"]["base_dir"]
            ) / f"couchbase-{repo.target}-{repo.distro}.list",
            context
        )


    # Holder for existing distro codenames, including the basic "linux" distro
    codenames: ClassVar[Dict[str, str]] = {"linux": "linux"}
    distrore: ClassVar[Optional[re.Pattern]] = None

    def load_release_list(self, brand: str) -> None:
        """
        Downloads the master list of releases for the specified "brand"
        of Linux distribution (ubuntu or debian currently). Returns a
        dict mapping standard names (eg "ubuntu22.04", "debian9") to the
        corresponding codename. For convenience also includes mappings
        from codenames to themselves.
        """

        logging.debug(f"Looking up available versions of '{brand}'")
        response = requests.get(f"https://endoflife.date/api/{brand}.json")
        data = response.json()

        for version_data in data:
            version = version_data["cycle"]
            codename = version_data["codename"].split()[0].lower()
            self.codenames[f"{brand}{version}"] = codename
            self.codenames[codename] = codename


    def detect_distro(self, pkgfile: pathlib.Path) -> str:
        """
        If the filename contains a recognizable Linux distribution or codename,
        return that. Otherwise error.
        """

        # Pre-populate mapping of codenames first time this is called
        if Aptly.distrore is None:
            self.load_release_list("ubuntu")
            self.load_release_list("debian")

            # Add these one-offs for slightly-older couchbase-lite-c packages
            self.codenames["raspbian9"] = "raspbian9"
            self.codenames["raspios10"] = "raspios10"
            distropattern = r"|".join([
                x.replace(".", "\.") for x in self.codenames.keys()
            ])

            logging.debug(f"Regex for matching distros: {distropattern}")
            Aptly.distrore = re.compile(f"({distropattern})")

        match = Aptly.distrore.search(pkgfile.name)
        if match is None:
            logging.fatal(
                f"Could not detect Linux distribution for {pkgfile} "
                f"(don't use --distro auto in this case)"
            )
            sys.exit(3)

        distro = self.codenames[match.group(1)]
        logging.debug(f"Identified distro '{distro}' for {pkgfile}")
        return distro


    debugre: ClassVar[re.Pattern] = re.compile("dbg_")

    def add_package(
        self, target: str, distro: str, pkgfile: pathlib.Path
    ) -> Optional[str]:
        """
        Represents a request to add a .deb to a specified repository. Returns
        the full name of the repository.
        """

        # Handle "auto" Linux distribution introspection
        if distro == "auto":
            distro = self.detect_distro(pkgfile)

        if self.debugre.search(pkgfile.name) is not None:
            logging.debug(f"Skipping debuginfo package {pkgfile}")
            return None

        # Remember this request for commit time
        repo = AptlyRepo(target, distro)
        self.dirty_repos[repo].add(pkgfile)
        return str(repo)


    def commit(self) -> None:
        """
        Processes all queued add_package requests
        """

        for (repo, pkgfiles) in self.dirty_repos.items():
            for pkgfile in pkgfiles:
                self.commit_package(repo, pkgfile)
            self.update_repo(repo)
            self.write_listfile(repo)
