#!/usr/bin/env python3

import argparse
import contextlib
import json
import os
import pprint
import re
import shutil
import sys
import xml.etree.ElementTree as ET

from subprocess import check_call, check_output


@contextlib.contextmanager
def remember_cwd():
    curdir = os.getcwd()
    try:
        yield
    finally:
        os.chdir(curdir)


def scan_manifests(manifest_repo="ssh://git@github.com/couchbase/manifest"):
    """
    Syncs to the "manifest" project from the given repository, and
    returns a list of metadata about all discovered manifests. This does
    leave things in a "manifest" subdir of the current working
    directory.
    """
    # Sync manifest project into local directory based on mangled URL
    os.makedirs("manifest", exist_ok=True)
    manifest_dir = os.path.join(
        os.getcwd(),
        "manifest",
        re.sub(r'[:/& ?]', '_', manifest_repo)
    )

    if not os.path.isdir(manifest_dir):
        check_call(["git", "clone", manifest_repo, manifest_dir])
    with remember_cwd():
        os.chdir(manifest_dir)
        print("Updating manifest repository...")
        check_call(["git", "fetch", "--all"])
        check_call(["git", "reset", "--hard", "origin/HEAD"])

    return get_metadata_for_products(manifest_dir)

def get_metadata_for_products(manifest_dir):
    """
    Given a local manifest directory, return metadata describing
    all manifests.
    manifest_dir: path to local manifest clone
    returns: dict (keyed by path to manifest) of dicts of metadata
    """
    # Scan the current directory for input manifests.
    manifests = {}
    with remember_cwd():
        os.chdir(manifest_dir)
        for root, dirs, files in os.walk("."):
            # Prune top-level dirs we don't want to walk
            if root == ".":
                if ".git" in dirs:
                    dirs.remove(".git")
                if "toy" in dirs:
                    dirs.remove("toy")
                if "released" in dirs:
                    dirs.remove("released")
                continue

            # Load manifest metadata where specified
            if "product-config.json" in files:
                # Strip leading "./" from root (pass character 2 onwards)
                prod_manifests = _get_metadata_for_product(
                    os.getcwd(),
                    root[2:]
                )
                manifests.update(prod_manifests)

    return manifests

def _load_product_config(manifest_dir, product_path):
    """
    Returns a tuple containg the "manifests" dict and the override product name
    (default None) from a product-config.json
    """

    prod_config = os.path.join(manifest_dir, product_path, "product-config.json")
    with open(prod_config, "r") as conffile:
        config = json.load(conffile)
    if "manifests" not in config:
        return {}
    return (config["manifests"], config.get("product", None))


def _get_metadata_for_product(manifest_dir, product_path):
    """
    Loads metadata about all manifests in a given product subdir
    manifest_dir: root of a manifest repository.
    product_path: relative path to subdir of repository. Subdir
    is presumed to have a "product-config.json" at the root.
    returns: dict (keyed by manifest paths) of dicts of metadata
    """

    config, override_product = _load_product_config(manifest_dir, product_path)
    prod_metadata = config.items()
    for manifest_path, metadata in prod_metadata:
        _append_manifest_metadata(
            metadata, manifest_dir, manifest_path, product_path, override_product
        )
    return prod_metadata


def _append_manifest_metadata(metadata, manifest_dir, manifest_path, product_path, override_product):
    """
    Extends a manifest-specific dict with additional metadata derived
    from the product path, product-config, and manifest contents.
    metadata: input dict to extend
    manifest_dir: root of manifest repository checkout
    manifest_path: path (relative to manifest_dir) to a manifest.xml
    product_path: path to root of product (directory containing
    a product-config.json)
    override_product: if product-config.json has a top-level "product" key,
    that value; otherwise None
    """

    if override_product is not None:
        # Override product (and product_path) if set in product-config.json
        product = override_product
    else:
        # Otherwise, product name is derived from product path
        product = product_path.replace('/', '::')

    # Have to actually parse the manifest to extract VERSION
    root = ET.parse(os.path.join(manifest_dir, manifest_path))
    verattr = root.find('project[@name="build"]/annotation[@name="VERSION"]')
    if verattr is not None:
        metadata['version'] = verattr.get('value', "0.0.0")
    else:
        metadata['version'] = "0.0.0"

    # Derived values are here
    metadata['product'] = product
    metadata['product_path'] = product_path
    metadata['manifest_path'] = manifest_path
    metadata['prod_name'] = product.split('::')[-1]
    metadata['build_job'] = metadata.get('jenkins_job', f'{product}-build')


def get_metadata_for_manifest(manifest_dir, manifest_path):
    """
    Alternate entrypoint for loading metadata about exactly one manifest.
    manifest_dir: root of a manifest repository checkout
    manifest_path: path (relative to manifest_dir) to a specific .xml file
    returns: dict of all known metadata about the product-version represented
    by the manifest
    """
    product_path = os.path.dirname(manifest_path)
    while not os.path.exists(os.path.join(
        manifest_dir, product_path, "product-config.json"
    )):
        product_path = os.path.dirname(product_path)
        if len(product_path) < 2:
            print (f"No product-config.json found above {manifest_path}!")
            sys.exit(1)
    config, override_product = _load_product_config(manifest_dir, product_path)
    metadata = config[manifest_path]
    _append_manifest_metadata(metadata, manifest_dir, manifest_path, product_path, override_product)
    return metadata

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument("-p", "--manifest-project", type=str,
                       default="ssh://git@github.com/couchbase/manifest",
                       help="Alternate git URL for manifest repository")
    group.add_argument("-d", "--manifest-dir", type=str,
                       help="Local manifest directory")
    parser.add_argument("-m", "--manifest-file", type=str,
                        default=None,
                        help="Specific manifest to show info about (default: all)")
    args = parser.parse_args()
    pp = pprint.PrettyPrinter(indent=2)

    if args.manifest_dir is not None:
        if args.manifest_file is not None:
            pp.pprint(get_metadata_for_manifest(
                args.manifest_dir, args.manifest_file
            ))
        else:
            pp.pprint(get_metadata_for_products(
                args.manifest_dir
            ))
    else:
        details = scan_manifests(args.manifest_project)
        if args.manifest_file is not None:
            pp.pprint(details[args.manifest_file])
        else:
            pp.pprint(details)
