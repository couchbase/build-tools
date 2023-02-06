#!/usr/bin/env python3

import re
import sys
import argparse
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
            continue
        # If project is already pointing to a tag, skip it
        if revision.startswith("refs/tags/"):
            continue
        # If project is already pointing to a branch with the same
        # name as the manifest's VERSION annotation, skip it
        if revision == product_version:
            continue
        # If master-only is specified and project isn't on master/main,
        # skip it. Note: we don't care if the manifest specifies a
        # different name for <default revision="">; this rule is about
        # git's normal default branch. So we don't compare against
        # default_revision here.
        if master_only and revision != "master" and revision != "main":
            continue
        # If project was explicitly skipped, skip it
        if project in args.skip_projects:
            continue
        # If specific projects were specified and this isn't one of them,
        # skip it
        if args.projects is not None and project not in args.projects:
            continue
        try:
            sha = sha_src_dict[path]['revision']
            result.attrib['revision'] = sha
            updated_projects += 1
            print(f"Locking {project} to {sha}")
        except KeyError as e:
            print(f"Error: {e} {project} not found in \"{args.sha_src}\" input file!")
            print()
            sys.exit(1)

    # write data
    tree.write(args.output, encoding='UTF-8',
               xml_declaration=True, pretty_print=True)
    print(f"\n{updated_projects} projects locked")
    print(f"Output manifest has been generated here: {args.output}")
    if updated_projects == 0:
        print("\n     WARNING: manifest unchanged!")
    print()


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
        default=['testrunner', 'product-texts']
    )
    parser.add_argument(
        '--projects',
        nargs='+',
        metavar='project',
        help='List of projects to lock (default all non-skipped projects)'
    )

    args = parser.parse_args()
    main(args)
