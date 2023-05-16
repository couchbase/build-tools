#!/usr/bin/env python3

import argparse
import re
import sys
import logging
from lxml import etree


def parse_src_input(input):
    # parse locked SHA build input to get lock revisions
    tree = etree.parse(input)

    input_lock_src = {}
    result_dict = tree.iterfind("//project")

    for result in result_dict:
        project = result.get('name')
        path = result.get('path', project)
        revision = result.get('revision', 'master')

        input_lock_src[path] = {
            'name': project,
            'revision': revision
        }

    return input_lock_src

def main(args):
    sha_src_dict = parse_src_input(args.sha_src)
    master_only = args.master_only

    # Read input manifest
    tree = etree.parse(args.input)

    # Determine default revision
    default_revision = "master"
    default_element = tree.find("default")
    if default_element is not None:
        default_revision = default_element.get("revision", default_revision)

    # Determine VERSION annotation
    product_version = "0.0.0"
    version_element = tree.find("//annotation[@name='VERSION']")
    if version_element is not None:
        product_version = version_element.get("value", product_version)

    # Loop through input_src file
    # Replace the git SHA from src_lock_input xml
    result_dict = tree.iterfind("project")
    sha_regex = re.compile(r'\b([a-f0-9]{40})\b')

    updated_projects = 0
    for result in result_dict:
        project = result.get('name')
        path = result.get('path', project)
        revision = result.get('revision', default_revision)
        # If project is already locked to a SHA, skip it
        if sha_regex.match(revision):
            logging.debug(f"Project {project} already locked to SHA")
            continue
        # If project is already pointing to a tag, skip it
        if revision.startswith("refs/tags/"):
            logging.debug(f"Project {project} locked to tag")
            continue
        # If project is already pointing to a branch with the same
        # name as the manifest's VERSION annotation, skip it (unless told
        # not to skip it)
        if revision == product_version and not args.lock_version_branches:
            logging.debug(
                f"Project {project} already locked "
                f"to version branch '{product_version}'")
            continue
        # If master-only is specified and project isn't on master/main,
        # skip it. Note: we don't care if the manifest specifies a
        # different name for <default revision="">; this rule is about
        # git's normal default branch. So we don't compare against
        # default_revision here.
        if master_only and revision != "master" and revision != "main":
            logging.debug(f"Project {project} on non-master branch {revision}")
            continue
        # If project was explicitly skipped, skip it
        if project in args.skip_projects:
            logging.debug(f"Project {project} skipped due to user request")
            continue
        # If specific projects were specified and this isn't one of them,
        # skip it
        if args.projects is not None and project not in args.projects:
            logging.debug(f"Project {project} not on list of explicit projects")
            continue
        try:
            sha = sha_src_dict[path]['revision']
            result.attrib['revision'] = sha
            updated_projects += 1
            logging.info(f"Locking {project} to {sha}")
        except KeyError as e:
            logging.fatal(f"Error: {e} {project} not found in \"{args.sha_src}\" input file!")
            sys.exit(1)

    # write data
    tree.write(args.output, encoding='UTF-8',
               xml_declaration=True, pretty_print=True)
    logging.info(f"{updated_projects} projects locked")
    logging.info(f"Output manifest has been generated here: {args.output}")
    if updated_projects == 0:
        logging.warning("manifest unchanged!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Create an updated manifest by locking projects to SHAs sourced from a build manifest"
    )
    parser.add_argument(
        '--input',
        help="Input manifest",
        required=True
    )
    parser.add_argument(
        '--sha-src',
        help="Build manifest that has locked SHAs",
        required=True
    )
    parser.add_argument(
        '--output',
        help="Output result xml file name"
        "default: out.xml",
        default='out.xml',
        required=False
    )
    parser.add_argument(
        '--master-only',
        action='store_true',
        help="Only lock projects on 'master' or 'main' branches"
    )
    parser.add_argument(
        '--skip-projects',
        nargs='+',
        metavar='project',
        help='List of projects to skip',
        default=['testrunner', 'product-texts', 'golang']
    )
    parser.add_argument(
        '--projects',
        nargs='+',
        metavar='project',
        help='List of projects to lock (default all non-skipped projects)'
    )
    parser.add_argument(
        '--lock-version-branches',
        action='store_true',
        help='Also lock projects that are pointing to VERSION-specific git branches'
    )
    parser.add_argument(
        '--debug',
        action='store_true',
        help='Enable debugging output'
    )

    args = parser.parse_args()

    # Initialize logging
    logging.basicConfig(
        stream=sys.stderr,
        format='%(asctime)s: %(levelname)s: %(message)s',
        level=logging.DEBUG if args.debug else logging.INFO
    )

    main(args)
