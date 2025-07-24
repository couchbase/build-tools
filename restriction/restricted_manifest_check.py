#!/usr/bin/env python

import os
import sys
import argparse
import pprint
from subprocess import check_call, check_output

script_dir = os.path.dirname(os.path.abspath(__file__))
build_from_manifest_path = os.path.abspath(os.path.join(script_dir, "..", "build-from-manifest"))
if build_from_manifest_path not in sys.path:
    sys.path.insert(0, build_from_manifest_path)
from manifest_util import get_manifest_dir, scan_manifests

"""
Intended to run as a Gerrit trigger. The following environment variables
must be set as Gerrit plugin would:
  GERRIT_REFSPEC  GERRIT_HOST  GERRIT_PORT  GERRIT_CHANGE_URL
"""

# Command-line args
def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("-p", "--manifest-project", type=str,
                      default="ssh://git@github.com/couchbase/manifest",
                      help="Alternate Git project for manifest")
  args = parser.parse_args()
  MANIFEST_PROJECT = args.manifest_project

  # Collect all restricted manifests that reference this branch
  manifests = scan_manifests(MANIFEST_PROJECT)
  manifest_dir = get_manifest_dir(MANIFEST_PROJECT)
  os.chdir(manifest_dir)
  check_call(["git", "fetch", "ssh://{}:{}/manifest".format(
    os.environ["GERRIT_HOST"], os.environ["GERRIT_PORT"]),
    os.environ["GERRIT_REFSPEC"]
    ])
  files = check_output([
    "git", "diff-tree", "--no-commit-id", "--name-only", "-r", "FETCH_HEAD"])
  failed = False
  for manifest in files.splitlines():
    if (manifest in manifests and
        "restricted" in manifests[manifest] and
         manifests[manifest]["restricted"]):
      print("\n\n\n*********\n{} is restricted and is being changed by {}!\n*********\n".format(
        manifest, os.environ["GERRIT_CHANGE_URL"]))
      failed = True
  if failed:
    sys.exit(1)
