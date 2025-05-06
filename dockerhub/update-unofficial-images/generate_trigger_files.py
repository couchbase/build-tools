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
        "couchbase-partners/redhat-openshift"
    ]:
        git.repo(f"{repo}")


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

    for registry, products in image_update_info.items():
        for product, editions in products.items():
            for edition, tags in editions.items():
                for tag, info in tags.items():
                    if info['rebuild_needed']:
                        build_job = info.get('build_job')
                        floating_tags = info.get('floating_tags', [])
                        architectures = info['architectures']

                        # Format floating tags for display
                        floating_tag_display = ""
                        if floating_tags:
                            floating_tag_list = ", ".join(floating_tags)
                            floating_tag_display = f" - floating tags: {floating_tag_list}"

                        edition_display = f"({edition}) " if edition != "default" else ""
                        needed_rebuilds[registry].append(
                            f"{product} {tag} {edition_display}[build job: {build_job or "None"}]{floating_tag_display}")
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
                            f.write(f"{parameters[build_job]["product"]}={product}{os.linesep}")
                            f.write(f"{parameters[build_job]["version"]}={tag}{os.linesep}")

                            # Pass edition to the build job if it's not the default edition
                            if edition != "default" and "edition" in parameters[build_job]:
                                f.write(f"{parameters[build_job]["edition"]}={edition}{os.linesep}")

                            # If floating tags are associated with the current tag, we
                            # need to let the build job know
                            if floating_tags and "update_edition" in parameters[build_job]:
                                f.write(f"{parameters[build_job]["update_edition"]}=TRUE{os.linesep}")

    if any(needed_rebuilds[registry] for registry in needed_rebuilds):
        logger.info("Rebuilds needed - printing summary")
        print(
            f"==============={os.linesep}Rebuilds needed{os.linesep}"
            f"===============")
        for registry, rebuilds in needed_rebuilds.items():
            if rebuilds:
                print(
                    f"{registry}:{os.linesep}"
                    f"{os.linesep.join(f'  {entry}' for entry in rebuilds)}")
    else:
        logger.info("No rebuilds needed")


if __name__ == '__main__':
    main()
