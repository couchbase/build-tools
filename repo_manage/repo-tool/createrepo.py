#!/usr/bin/env -S python3 -u

"""
Simple wrapper around the createrepo_c command-line utility.
"""

import logging
import pathlib
import re
import shutil
import sys

from collections import defaultdict
from util import Action, render_template, run, run_output
from typing import ClassVar, Dict, NamedTuple, Optional, Set


class RpmAction(NamedTuple):
    pkgfile: pathlib.Path
    action: Action
    repofile: pathlib.Path


class Createrepo:

    # This is a ClassVar so that it can be shared by YumRepo. It's a little
    # weird because it's initialized in the Createrepo constructor, but
    # Createrepo is effectively a singleton so it works OK.
    targets_conf: ClassVar[Dict]

    class YumRepo:
        """
        Inner class representing a single on-disk yum repository.
        """
        target: str
        target_basedir: pathlib.Path
        distro: str
        arch: str
        dir: pathlib.Path

        def __init__(self, target: str, distro: str, arch: str) -> None:
            self.target = target
            self.distro = distro
            self.arch = arch
            self.target_basedir = pathlib.Path(
                Createrepo.targets_conf[target]["local"]["base_dir"]
            )
            self.dir = self.target_basedir / "rpms" \
                / self.target / self.distro / self.arch

        def __repr__(self) -> str:
            return f"{self.target}:{self.distro}:{self.arch}"

        def repo_dir(self) -> pathlib.Path:
            return self.dir


    def __init__(self, createrepo_conf: Dict, targets_conf: Dict) -> None:
        self.script_dir = pathlib.Path(__file__).resolve().parent
        self.gpg_key = createrepo_conf["gpg_key"]
        Createrepo.targets_conf = targets_conf
        self.dirty_repos: Dict[Createrepo.YumRepo, Set[pathlib.Path]] = \
            defaultdict(set)


    def commit_package(self, repo: YumRepo, rpmact: RpmAction) -> None:
        """
        Imports/Removes a package file in a specified yum repository, creating
        said repository if necessary. Signs the RPM on the way in.
        """

        # First ensure repository directory exists
        repo_dir = repo.repo_dir()
        if not repo_dir.is_dir():
            logging.info(f"Initializing yum repo {repo_dir}")
            repo_dir.mkdir(exist_ok=True, parents=True)

        match rpmact.action:
            case Action.ADD:
                # Copy the .rpm into target directory - use regular copy so the
                # rpm modtime is "now"
                pkgfile = rpmact.pkgfile
                logging.info(f"Importing {pkgfile} into yum repo {repo_dir}")
                repofile = rpmact.repofile
                shutil.copyfile(pkgfile, repofile)

                # GPG sign it
                logging.debug(f"GPG signing {repofile}")
                run([
                    'rpm', '--addsign', str(repofile),
                    '-D', '__gpg /usr/bin/gpg',
                    '-D', '_signature gpg',
                    '-D', f'_gpg_name {self.gpg_key}'
                ])
            case Action.REMOVE:
                # Just delete the file from the repo
                rpmact.repofile.unlink()


    def update_repo(self, repo: YumRepo) -> None:
        """
        Updates yum metadata in specified yum repository
        """

        repo_dir = repo.repo_dir()
        logging.info(f"Updating yum metadata in repo {repo_dir}")
        run(f"createrepo_c --update --retain-old-md=5 --compatibility {repo_dir}")

        # GPG sign the repomd
        repomdfile = repo_dir / "repodata" / "repomd.xml"
        logging.debug(f"GPG signing {repomdfile}")
        run([
            'gpg', '--detach-sign', '--armor', '--yes',
            '--local-user', str(self.gpg_key), str(repomdfile)
        ])


    def write_repofile(self, repo: YumRepo) -> None:
        """
        Saves a reference .repo file for loading the target:distro yum
        repository (comprising any available architecture subdirectories)
        """

        context = {
            "target": repo.target,
            "distro": repo.distro,
            "arch": repo.arch,
            "bucket": self.targets_conf[repo.target]["s3"]["bucket"],
            "prefix": self.targets_conf[repo.target]["s3"]["prefix"],
            "transport": self.targets_conf[repo.target]["s3"]["transport"],
        }
        render_template(
            self.script_dir / "tmpl" / "yumarchive.repo.j2",
            repo.target_basedir / \
                f"couchbase-{repo.target}-{repo.distro}-{repo.arch}.repo",
            context
        )

    distrore: ClassVar[re.Pattern] = re.compile(
        r"("
        r"  (?P<rhel>(rhel|oel|centos)(?P<rhelver>\d+)) | "
        r"  (?P<amzn>amzn\d+) | "
        r"  (?P<suse>suse) | "
        r"  (?P<linux>linux)"
        r")",
        re.VERBOSE
    )

    def detect_distro(self, pkgfile: pathlib.Path) -> Optional[str]:
        """
        If the filename contains a recognizable Linux distribution name,
        return that. Otherwise error.
        """

        match = self.distrore.search(pkgfile.name)
        if match is None:
            logging.fatal(
                f"Could not detect Linux distribution for {pkgfile} "
                f"(don't use --distro auto in this case)"
            )
            sys.exit(3)

        # RPM-based distro naming convention is just "fooXX" where XX is
        # an integer. For us, we group all RHEL-like packages together
        # under "rhel" since they're mutually compatible, and leave
        # "amzn" separate. And we ignore suse for now.
        if match.group("suse"):
            logging.debug(f"Skipping SUSE package {pkgfile}")
            return None
        elif match.group("rhel"):
            distro = f'rhel{match.group("rhelver")}'
        else:
            distro = match.group("amzn") or match.group("linux")
        logging.debug(f"Identified distro '{distro}' for {pkgfile}")
        return distro


    debugre: ClassVar[re.Pattern] = re.compile("debuginfo|asan")

    def add_action(
        self, target: str, distro: str, pkgfile: pathlib.Path, action: Action
    ) -> Optional[str]:
        """
        Represents a request to add a .rpm to a specified repository. Returns
        the full name of the repository.
        """

        # Don't add debug files
        if self.debugre.search(pkgfile.name) is not None:
            logging.debug(f"Skipping debuginfo/asan package {pkgfile}")
            return None

        # Handle "auto" Linux distribution introspection
        if distro == "auto":
            use_distro = self.detect_distro(pkgfile)
            if use_distro is None:
                # Would have already logged why it was ignored
                return None
            distro = use_distro

        # Check repository to see if this rpm already exists (can't actually
        # check if it's "the same file" or not because the one in repo_dir will
        # be signed)
        arch = run_output(f'rpm --qf %{{arch}} -qp {str(pkgfile)}').strip()
        repo = Createrepo.YumRepo(target, distro, arch)
        repo_dir = repo.repo_dir()
        repofile = repo_dir / pkgfile.name
        exists = repofile.exists()

        # Obtain package information from .rpm file, and save as an Action
        rpmact = RpmAction(
            pkgfile,
            action,
            repofile
        )

        # Don't record an action that won't do anything
        if action == Action.ADD and exists:
            logging.debug(f"Skipping add of already-existing rpm {pkgfile}")
            return None
        if action == Action.REMOVE and not exists:
            logging.debug(f"Skipping remove of non-existent rpm {pkgfile}")
            return None

        # Remember this request for commit time
        self.dirty_repos[repo].add(rpmact)
        return str(repo)


    def commit(self) -> None:
        """
        Processes all queued add_package requests
        """

        for (repo, rpmactions) in self.dirty_repos.items():
            for rpmact in rpmactions:
                self.commit_package(repo, rpmact)
            self.update_repo(repo)

            # We may end up calling this redundantly if we have RPMs for
            # multiple architectures in the same target:distro, but it's
            # easier just call this every time - it's cheap enough to
            # generate the .repo file
            self.write_repofile(repo)


    def recreate_repofiles(self, target: str) -> None:
        """
        Re-creates the .repo file for each known repository in target
        """

        base_dir = pathlib.Path(self.targets_conf[target]["local"]["base_dir"])
        target_basedir = base_dir / "rpms" / target
        for distro_dir in target_basedir.iterdir():
            for arch_dir in distro_dir.iterdir():
                self.write_repofile(
                    Createrepo.YumRepo(
                        target, distro_dir.name, arch_dir.name
                    )
                )
