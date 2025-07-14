#!/usr/bin/env -S uv run
# /// script
# requires-python = "==3.12.3"
# dependencies = ['packaging', 'requests']
# [tool.uv]
# exclude-newer = "2025-02-19T00:00:00Z"
# ///

import argparse
import logging
import os
import shutil
from src.wrappers.registry import analyze_images
from src.wrappers.logging import setup_logging
from src.wrappers.collections import defaultdict
from src.wrappers import git
from src.metadata import all_products, image_info, REGISTRIES
from datetime import datetime

setup_logging()
logger = logging.getLogger(__name__)

graph = defaultdict()

# Parameters which will be passed to the build jobs
parameters = {
    "update-dockerhub": {
        "product": "PRODUCT",
        "version": "VERSIONS",
        "edition": "EDITIONS",
        "update_edition": "UPDATE_EDITION"
    },
    "update-rhcc": {
        "product": "PRODUCT",
        "version": "VERSION"
    },
    "couchbase-k8s-microservice-republish": {
        "product": "PRODUCT",
        "version": "VERSION"
    }
}


def clone_repos():
    """Clone required repositories for container analysis"""
    logger.info("Cloning required repositories")
    os.makedirs("repos", exist_ok=True)
    for repo in [
        "couchbase/docker",
        "couchbase/manifest",
        "couchbase/product-metadata",
        "couchbase-partners/redhat-openshift",
        "couchbase/couchbase-elasticsearch-connector",
    ]:
        git.repo(f"{repo}")


def create_trigger_file(registry, product, edition, tag, build_job, floating_tags):
    repo = image_info(product)["github_repo"]

    # Generate filename for the trigger file
    edition_part = f"-{edition}" if edition != "default" else ""
    if repo == "couchbase/docker":
        filename = f"triggers/{registry}-{product}{edition_part}-{tag}-couchbase-republish.properties"
    else:
        filename = f"triggers/{registry}-{product}{edition_part}-{tag}-k8s-republish.properties"

    logger.debug(f"Creating trigger file: {filename}")

    with open(filename, "w") as f:
        f.write(f"REGISTRY={registry}{os.linesep}")
        f.write(f"BUILD_JOB={build_job}{os.linesep}")
        f.write(f"{parameters[build_job]['product']}={product}{os.linesep}")
        f.write(f"{parameters[build_job]['version']}={tag}{os.linesep}")

        # Pass edition to the build job if it's not the default edition
        if edition != "default" and "edition" in parameters[build_job]:
            f.write(f"{parameters[build_job]['edition']}={edition}{os.linesep}")

        # If floating tags are associated with the current tag, we
        # need to let the build job know
        if floating_tags and "update_edition" in parameters[build_job]:
            f.write(f"{parameters[build_job]['update_edition']}=true{os.linesep}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Rebuilds containers on base image changes")

    parser.add_argument(
        "-l",
        "--log-level",
        help="Log level (DEBUG, INFO, WARNING, ERROR, CRITICAL)",
        default="INFO"
    )
    parser.add_argument(
        "-p",
        "--product",
        help="Product(s) - a product or comma-separated list of products"
    )
    parser.add_argument(
        "-e",
        "--edition",
        help="Edition(s) - an edition or comma separated list of editions",
        default="community,enterprise,default"
    )
    parser.add_argument(
        "-v",
        "--version",
        help="Version(s) - a version or comma separated list of versions",
    )
    parser.add_argument(
        "-r",
        "--registry",
        help="Registry(s) - a registry or comma separated list of registries "
        "(dockerhub and/or rhcc)"
    )

    args = parser.parse_args()
    logging.getLogger().setLevel(args.log_level.upper())

    # Clone repos before importing metadata
    clone_repos()

    if not args.product:
        args.product = ",".join(all_products())
    logger.debug(f"Parsed arguments: {args}")

    registries = args.registry.split(",") if args.registry else REGISTRIES.keys()
    for registry in registries:
        if registry not in ["dockerhub", "rhcc"]:
            logger.error(f"Invalid registry '{registry}' specified - must be one of: dockerhub, rhcc")
            return 1

    products = args.product.split(",")
    editions = args.edition.split(",")
    versions = args.version.split(",") if args.version else []

    logger.debug(
        f"Analyzing with parameters - registries: {registries}, "
        f"products: {products}, editions: {editions}, versions: {versions}")
    image_update_info = analyze_images(
        registries=registries,
        products=products,
        editions=editions,
        versions=versions
    )

    # Ensure triggers directory exists and is empty
    if os.path.exists("triggers"):
        logger.debug("Removing existing triggers directory")
        shutil.rmtree("triggers")
    os.makedirs("triggers", exist_ok=True)

    # Create trigger files for images that need rebuilt
    logger.info("Creating trigger files for images needing rebuilds")
    needed_rebuilds = {registry: [] for registry in REGISTRIES}
    skipped_rebuilds = {registry: [] for registry in REGISTRIES}
    ineffective_rebuilds = {registry: [] for registry in REGISTRIES}

    for registry, products_data in image_update_info.items():
        for product, editions_data in products_data.items():
            for edition, tags_data in editions_data.items():
                for tag, info in tags_data.items():
                    build_job = info.get('build_job')
                    base_image = info.get('base_image', '')
                    floating_tags = info.get('floating_tags', [])
                    edition_display = f"({edition}) " if edition != "default" else ""
                    heading = f"{product} {tag} {edition_display}[job: {build_job or 'None'}]"

                    details = []
                    if floating_tags:
                        details.append(f"  Floating tags: {', '.join(floating_tags)}")
                    if base_image:
                        details.append(f"  Base image: {base_image}")

                    if info.get('rebuild_ineffective', False):
                        packages_in_common = info.get('packages_in_common', [])
                        if packages_in_common:
                            details.append(f"  Common package updates (also in base): {', '.join(packages_in_common)}")
                        details.append("  Status: Ineffective rebuild (review Dockerfile)")
                        ineffective_rebuilds[registry].append(heading)
                        ineffective_rebuilds[registry].extend(details)
                    elif info.get('rebuild_needed', False):
                        if ('base_created' in info and 'product_created' in info
                                and info['base_created'] > info['product_created']):
                            details.append("  Status: Rebuild needed (newer base image)")
                        elif info.get('packages_to_update'):
                            details.append(f"  Product-specific updates: {', '.join(info['packages_to_update'])}")
                            details.append("  Status: Rebuild needed (product-specific package updates)")
                        else:
                            details.append("  Status: Rebuild needed (unknown reason - check logs)")

                        if build_job:
                            needed_rebuilds[registry].append(heading)
                            needed_rebuilds[registry].extend(details)
                            create_trigger_file(registry, product, edition, tag, build_job, floating_tags)
                        else:
                            details.append("  Status: Skipped (no build_job defined, but rebuild otherwise needed)")
                            skipped_rebuilds[registry].append(heading)
                            skipped_rebuilds[registry].extend(details)
                    else:
                        skipped_reason = info.get('skipped_reason')
                        if skipped_reason:
                            details.append(f"  Status: Skipped ({skipped_reason})")
                        elif info.get('distroless', False):
                            details.append("  Status: Skipped (distroless image, no package checks)")
                        else:
                            details.append("  Status: Skipped (no actionable updates found)")

                        skipped_rebuilds[registry].append(heading)
                        skipped_rebuilds[registry].extend(details)

    # Print skipped rebuilds if there are any
    if any(skipped_rebuilds[registry] for registry in skipped_rebuilds):
        logger.info("Rebuilds skipped - printing summary")
        print(
            f"==============={os.linesep}Rebuild skips{os.linesep}"
            f"===============")
        for registry, skips in skipped_rebuilds.items():
            if skips:
                print(f"{registry}:")
                for entry in skips:
                    print(f"  {entry}")
                print("")  # Add extra newline between registries

    if any(needed_rebuilds[registry] for registry in needed_rebuilds):
        logger.info("Rebuilds needed - printing summary")
        print(
            f"==============={os.linesep}Rebuilds needed{os.linesep}"
            f"===============")
        for registry, rebuilds in needed_rebuilds.items():
            if rebuilds:
                print(f"{registry}:")
                for entry in rebuilds:
                    print(f"  {entry}")
                print("")  # Add extra newline between registries
    else:
        logger.info("No rebuilds needed")

    # Print ineffective rebuilds if there are any
    if any(ineffective_rebuilds[registry] for registry in ineffective_rebuilds):
        logger.info("Ineffective rebuilds detected - review Dockerfiles")
        print(
            f"==================================={os.linesep}Ineffective Rebuilds (Review Dockerfile){os.linesep}"
            f"===================================")
        for registry, ineffectives in ineffective_rebuilds.items():
            if ineffectives:
                print(f"{registry}:")
                for entry in ineffectives:
                    print(f"  {entry}")
                print("") # Add extra newline between registries


if __name__ == '__main__':
    main()
