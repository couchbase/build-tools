#!/usr/bin/env -S uv run
# /// script
# requires-python = "==3.11.11"
# dependencies = ['httplib2', 'xmltodict']
# [tool.uv]
# exclude-newer = "2025-05-16T00:00:00Z"
# ///

import argparse
import contextlib
import logging
import os
import pathlib
import shutil
import sys
import subprocess
import xmltodict # type: ignore
import re

from typing import Dict, Iterator, List
from urllib.parse import urlsplit

class V8ManifestGenerator:

    tag: str
    work_dir: pathlib.Path
    debug: bool
    cleanup: bool
    manifest: Dict
    output_manifest: pathlib.Path

    #
    # Utility methods
    #
    @contextlib.contextmanager
    def pushd(self, new_dir: pathlib.Path) -> Iterator:
        """
        Context manager for handling a given set of code/commands
        being run from a given directory on the filesystem
        """

        old_dir = os.getcwd()
        os.chdir(new_dir)
        logging.debug(f"++ pushd {os.getcwd()}")

        try:
            yield
        finally:
            os.chdir(old_dir)
            logging.debug(f"++ popd (pwd now: {os.getcwd()})")


    def run(self, cmd: List, **kwargs) -> subprocess.CompletedProcess:
        """
        Echo command being executed - helpful for debugging
        """

        # Print the command for reference
        if self.debug:
            cmdline = " ".join([
                f"'{str(x)}'" if ' ' in str(x) else str(x) for x in cmd
            ])
            logging.debug(f"++ {cmdline}")

        # If caller requested capture_output, don't muck with stderr/stdout;
        # otherwise, suppress them unless debugging
        if not "capture_output" in kwargs and not self.debug:
            kwargs["stdout"] = subprocess.DEVNULL
            kwargs["stderr"] = subprocess.DEVNULL

        return subprocess.run(cmd, **kwargs, check=True)


    def __init__(self, tag: str, work_dir: str) -> None:
        """
        Get ready
        """

        self.tag = tag
        self.work_dir = pathlib.Path(work_dir).resolve()
        self.depot_tools_dir = self.work_dir / "depot_tools"
        if not self.work_dir.exists():
            logging.debug(f"Creating work dir {work_dir}")
            self.work_dir.mkdir(parents=True)
        self.debug = False
        self.cleanup = False

        # Initialize the in-memory manifest structure, in a way that
        # xmltodict will like
        self.manifest = {
            "manifest": {
                "remote": [],
                "project": [],
            }
        }


    def set_debug(self, debug: bool) -> None:
        """
        Enable debug logging
        """

        self.debug = debug


    def set_cleanup(self, cleanup: bool) -> None:
        """
        Specify whether to clean up the working directory when complete
        """

        self.cleanup = cleanup


    def set_output_manifest(self, output_manifest: str) -> None:
        """
        Specify the final output XML file
        """

        self.output_manifest = pathlib.Path(output_manifest).resolve()


    def generate(self) -> None:
        """
        Do the things
        """
        with self.pushd(self.work_dir):
            self.fetch_depot_tools()
            self.fetch_v8()

        self.construct_manifest()
        self.write_manifest()

        if self.cleanup:
            logging.debug(f"Removing work dir {self.work_dir}")
            shutil.rmtree(self.work_dir)


    def fetch_depot_tools(self) -> None:
        """
        Check out Google's depot_tools repo
        """

        depot_tools_dir = self.work_dir / "depot_tools"
        if depot_tools_dir.exists():
            logging.info("Updating depot_tools")
            with self.pushd(depot_tools_dir):
                self.run(['git', 'fetch', '--all'])
                self.run(['git', 'checkout', 'origin/main'])
        else:
            logging.info("Cloning depot_tools")
            self.run([
                'git', 'clone',
                'https://chromium.googlesource.com/chromium/tools/depot_tools.git'
            ])

        # Also create a fake directory for all the commands in depot_tools
        # that we don't actually want to run
        logging.debug("Creating fake bin dir")
        fake_bin = self.work_dir / "fakebin"
        fake_bin.mkdir(exist_ok = True)
        for tool in ["cipd"]:
            with open(fake_bin / tool, "w") as f:
                f.write(f"#!/bin/bash\n\necho 'Not running {tool}'\n")
                os.chmod(fake_bin / tool, 0o755)
        os.environ["PATH"] = f'{fake_bin}:{self.depot_tools_dir}:{os.environ["PATH"]}'


    def fetch_v8(self) -> None:
        """
        Pretend to run 'fetch v8' to get initial source code
        """

        # It seems all 'fetch' does is create this .gclient file and then
        # run "gclient sync", so we'll just do that.
        logging.debug("Creating .gclient file")
        gclient_config = """solutions = [
  {{
    "url": "https://chromium.googlesource.com/v8/v8.git@{tag}",
    "managed": False,
    "name": "v8",
    "deps_file": "DEPS",
    "custom_deps": {{}},
  }},
]
"""
        with open(".gclient", "w") as f:
            f.write(gclient_config.format(tag=self.tag))
        self.run(['cat', '.gclient'])

        logging.info("Syncing v8 source (will take a while)")
        # This should work anywhere, and avoids as much of depot_tools
        # as possible
        os.environ["DEPOT_TOOLS_UPDATE"] = "0"
        os.environ["VPYTHON_BYPASS"] = "manually managed python not supported by chrome operations"

        self.run([
            "uv", "run",
            "-p", f"{sys.version.split()[0]}",
            "--with", "httplib2",
            "--with", "xmltodict",
            self.work_dir / "depot_tools" / "gclient.py",
            "sync", "--with_tags", "--reset", "--delete_unversioned_trees",
            "--nohooks", "--no_bootstrap", "--shallow", "--no-history", "-vvv"
        ])


    def construct_manifest(self) -> None:
        """
        Walk the v8 tree finding git directories, and construct an
        in-memory manifest
        """

        logging.info("Constructing manifest")
        for root, dirs, files in os.walk(self.work_dir / "v8"):
            if not ".git" in dirs:
                continue
            proc = self.run(
                ["git", "-C", root, "config", "remote.origin.url"],
                capture_output=True
            )
            url = proc.stdout.decode().rstrip()
            proc = self.run(
                ["git", "-C", root, "rev-parse", "HEAD"],
                capture_output=True
            )
            sha = proc.stdout.decode().rstrip()
            rel_path = os.path.relpath(root, self.work_dir)
            self.add_project(url, rel_path, sha)


    def add_project(
        self, url: str, rel_path: str, sha: str, name: str = None
    ) -> Dict[str, str]:
        """
        Given a relative path and SHA, add a <project> entry to the
        in-memory manifest. Return said <project> dict.
        """

        # Create/Look up remote
        remote = self.add_remote(url)

        # Construct project name so it's unique
        project = os.path.basename(url) if name is None else name
        project = project[:-4] if project.endswith('.git') else project
        logging.debug(f"Adding project {project} at {rel_path} revision {sha}")
        project_dict = {
            "@name": project,
            "@path": rel_path,
            "@revision": sha,
            "@remote": remote,
        }
        self.manifest["manifest"]["project"].append(project_dict)
        return project_dict


    def add_remote(self, url: str) -> str:
        """
        Given a git URL, add a <remote> entry to the in-memory manifest
        if one is needed. Return the remote name.
        """

        url_root = os.path.dirname(url)
        remote_url = url_root + "/"
        for remote in self.manifest["manifest"]["remote"]:
            if remote["@fetch"] == remote_url:
                logging.debug(f"Not adding remote for {remote_url} - already exists")
                return remote["@name"]

        bits = urlsplit(url_root)
        if bits.path == "":
            # Fallback for really short URLs, like gn's
            name = bits.netloc
        else:
            name_b = os.path.basename(bits.path)
            name_a = os.path.basename(os.path.dirname(bits.path))
            name = f"{name_a}-{name_b}" if name_a != "" else name_b
        logging.debug(f"Adding remote {name} at {remote_url}")
        self.manifest["manifest"]["remote"].append({
            "@name": name,
            "@fetch": remote_url,
        })
        return name


    def write_manifest(self) -> None:
        """
        Output the in-memory manifest to an XML file
        """

        # Add our own necessary manifest additions
        logging.debug("Adding build and build-tools projects")
        self.add_project(
            "https://gn.googlesource.com/gn",
            "gn",
            "main"
        )
        self.add_project(
            "https://github.com/couchbase/build-tools",
            "build-tools",
            "master"
        )
        build_project = self.add_project(
            "https://github.com/couchbase/build",
            "cbbuild",
            "ca92a4864bbcc878fb7b00f3c94c2c534c7ebd1a",
            name="build"
        )
        build_project["annotation"] = {
            "@name": "VERSION",
            "@value": self.tag,
            "@keep": "true",
        }

        logging.info(f"Saving final manifest {self.output_manifest}")
        with open(self.output_manifest, "w") as m:
            m.write(xmltodict.unparse(self.manifest, pretty=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generate a repo manifest for V8 from a given V8 tag"
    )
    parser.add_argument(
        '-t', '--tag', type=str, required=True,
        help="V8 tag to reference"
    )
    parser.add_argument(
        '-o', '--output-manifest', type=str, default="v8manifest.xml",
        help="Output XML manifest file to generate"
    )
    parser.add_argument(
        '-w', '--work-dir', type=str, default='/tmp/v8manifest',
        help="Working directory to use (will be created and deleted!)"
    )
    parser.add_argument(
        '--cleanup', action="store_true",
        help="Remove working directory after completion"
    )
    parser.add_argument(
        '-d', '--debug', action="store_true",
        help="Enable debug output"
    )

    args = parser.parse_args()

    # Initialize logging
    logging.basicConfig(
        stream=sys.stderr,
        format='%(asctime)s: %(levelname)s: %(message)s',
        level=logging.DEBUG if args.debug else logging.INFO
    )

    generator = V8ManifestGenerator(args.tag, args.work_dir)
    generator.set_debug(args.debug)
    if args.cleanup:
        generator.set_cleanup(True)
    generator.set_output_manifest(args.output_manifest)
    generator.generate()
