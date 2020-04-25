#!/usr/bin/env python3

import argparse
import contextlib
import json
import os
import pprint
import shutil
import xml.etree.ElementTree as ET

from subprocess import check_call, check_output


@contextlib.contextmanager
def remember_cwd():
    curdir = os.getcwd()
    try:
        yield
    finally:
        os.chdir(curdir)


def scan_manifests(manifest_repo="git://github.com/couchbase/manifest"):
    """
    Syncs to the "manifest" project from the given repository, and
    returns a list of metadata about all discovered manifests
    """
    # Sync manifest project
    if os.path.isdir("manifest"):
        with remember_cwd():
            os.chdir("manifest")
            url = check_output(
                ['git', 'ls-remote', '--get-url', 'origin']
            ).decode().strip()
        if url != manifest_repo:
            print('"manifest" dir pointing to different remote, removing..')
            shutil.rmtree("manifest")

    if not os.path.isdir("manifest"):
        check_call(["git", "clone", manifest_repo, "manifest"])

    with remember_cwd():
        os.chdir("manifest")
        print("Updating manifest repository...")
        check_call(["git", "pull"])

        # Scan the current directory for build manifests.
        manifests = {}
        for root, dirs, files in os.walk("."):
            # Prune all legacy manifests, including those in the top-level dir
            if root == ".":
                dirs.remove(".git")
                if "toy" in dirs:
                    dirs.remove("toy")

                if "released" in dirs:
                    dirs.remove("released")

                continue

            # Load manifest metadata where specified
            if "product-config.json" in files:
                with open(os.path.join(root, "product-config.json"),
                          "r") as conffile:
                    config = json.load(conffile)
                    if "manifests" not in config:
                        continue
                    # Strip leading "./" from product path
                    add_manifests(
                        manifests,
                        config["manifests"],
                        root[2:],
                        config.get("product")
                    )

    return manifests

def add_manifests(manifests, prod_manifests, product_path, override_product):
    """
    Adds all manifests for a product (ie, a single
    product-config.json), applying appropriate derived
    values
    """

    # QQQ we do NOT support per-manifest overrides of "product" here;
    # that feature should be considered deprecated

    if override_product is not None:
        # Override product (and product_path) if set in product-config.json
        product = override_product
        product_path = override_product.replace('::', '/')
    else:
        # Otherwise, product name is derived from product path
        product = product_path.replace('/', '::')

    for manifest, values in prod_manifests.items():
        # Have to actually parse the manifest to extract VERSION
        root = ET.parse(manifest)
        verattr = root.find('project[@name="build"]/annotation[@name="VERSION"]')
        if verattr is not None:
            values['version'] = verattr.get('value', "0.0.0")
        else:
            values['version'] = "0.0.0"

        # Derived values are here
        values['product'] = product
        values['product_path'] = product_path
        values['prod_name'] = product.split('::')[-1]
        values['build_job'] = values.get('jenkins_job', f'{product}-build')
        manifests[manifest] = values


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("-p", "--manifest-project", type=str,
                        default="git://github.com/couchbase/manifest",
                        help="Alternate git URL for manifest repository")
    parser.add_argument("-m", "--manifest-file", type=str,
                        default=None,
                        help="Specific manifest to show info about (default: all)")
    args = parser.parse_args()

    details = scan_manifests(args.manifest_project)

    pp = pprint.PrettyPrinter(indent=2)
    if args.manifest_file is not None:
        pp.pprint(details[args.manifest_file])
    else:
        pp.pprint(details)
