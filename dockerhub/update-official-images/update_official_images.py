#!/usr/bin/env -S uv run
# /// script
# requires-python = "==3.12.3"
# dependencies = ['packaging', 'requests']
# [tool.uv]
# exclude-newer = "2025-05-07T00:00:00Z"
# ///

import argparse
import contextlib
import datetime
import json
import logging
import os
import re
import requests
import subprocess
import sys
import uuid
from packaging.version import Version

script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(script_dir, "..", "..", "build-from-manifest"))
import manifest_util

# Constants
REPOS_DIR = "repos"
REPOS = [
    "ssh://git@github.com/couchbase/docker",
    "ssh://git@github.com/couchbase/manifest",
    "ssh://git@github.com/couchbase/product-metadata",
    "ssh://git@github.com/couchbasebuild/dockerhub-official-images"
]
IMAGES = {
    "couchbase-server": {
        "unofficial": "couchbase/server",
        "official": "couchbase"
    }
}
HEADER = """Maintainers: Couchbase Docker Team <docker@couchbase.com> (@cb-robot)
GitRepo: https://github.com/couchbase/docker

"""
BASE_EOL_DATES = {}


@contextlib.contextmanager
def remember_cwd():
    curdir = os.getcwd()
    try:
        yield
    finally:
        os.chdir(curdir)


# Set up logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def clone_repos():
    """Clone or update required git repositories."""
    logger.debug("Creating repos directory if it doesn't exist")
    os.makedirs(REPOS_DIR, exist_ok=True)

    for repo in REPOS:
        repo_name = repo.split('/')[-1]
        repo_path = os.path.join(REPOS_DIR, repo_name)
        action = 'Fetching changes for' if os.path.exists(
            repo_path) else 'Cloning'
        logger.debug(f"{action} repository: {repo_name}")
        print(f"{action} `{repo_name}`...")
        subprocess.run(
            ["../../utilities/clean_git_clone", repo, repo_path],
            check=True
        )


def get_tags(repo):
    """Get sorted list of tags."""
    logger.debug(f"Getting tags for repository: {repo}")
    result = subprocess.run(
        ["skopeo", "list-tags", f"docker://docker.io/{repo}"],
        capture_output=True, text=True, check=True
    )
    tags = [tag for tag in reversed(json.loads(result.stdout)["Tags"])]
    logger.debug(f"Found {len(tags)} tags")
    return tags


def query_endoflife_date(base_image, base_version):
    """
    Query the endoflife.date API for a specific base image and version.

    Returns a tuple (is_eol, eol_date) where:
    - is_eol is True if the base image version has reached end of life, False otherwise
    - eol_date is the EOL date as a string in YYYY-MM-DD format, or None if not found
    """
    logger.debug(
        f"Querying endoflife.date API for {base_image}:{base_version}")
    try:
        # Query endoflife.date API for the base image
        api_url = f"https://endoflife.date/api/{base_image}.json"
        response = requests.get(api_url)

        if response.status_code == 200:
            eol_data = response.json()
            for release in eol_data:
                if release.get("cycle") == base_version:
                    eol_date = release.get("eol")
                    if eol_date and eol_date != "false":
                        # Check if EOL date has passed
                        if isinstance(eol_date, str):
                            eol_datetime = datetime.datetime.strptime(
                                eol_date, "%Y-%m-%d")
                            is_eol = eol_datetime <= datetime.datetime.now()
                            return is_eol, eol_date
        else:
            logger.warning(
                f"Failed to get EOL data for {base_image}: HTTP {response.status_code}")
            sys.exit(1)
    except Exception as e:
        logger.warning(f"Error checking EOL for {base_image}: {e}")
        sys.exit(5)

    return False, None


def base_eol(product, stripped_version):
    """
    Check the FROM statement in the Dockerfile to see if it's using a base image that has reached end of life.

    Uses https://endoflife.date/api/{product}.json to check if the base image has reached end of life.

    Returns a tuple (is_eol, eol_date) where:
    - is_eol is True if the base image version has reached end of life, False otherwise
    - eol_date is the EOL date as a string in YYYY-MM-DD format, or None if not found
    """
    logger.debug(
        f"Checking base image EOL for {product} version {stripped_version}")
    dockerfile = os.path.join(
        REPOS_DIR, "docker", "enterprise", product, stripped_version, "Dockerfile")
    if not os.path.exists(dockerfile):
        logger.warning(
            f"Dockerfile not found for {product} version {stripped_version}")
        return False, None

    last_from = None
    base_image = None
    base_version = None
    with open(dockerfile) as f:
        for line in f:
            if line.startswith("FROM"):
                parts = line.split()
                # Handle both "FROM image" and "FROM image AS alias" formats
                last_from = parts[1]

                # Extract base image and version
                if ":" in last_from:
                    base_image, base_version = last_from.split(":")
                    # Handle cases like ubuntu:20.04, debian:buster, etc.
                    if base_image in ["ubuntu", "debian", "centos", "alpine"]:
                        logger.debug(
                            f"Base image: {base_image}:{base_version}")
                        break

    if not base_image or not base_version:
        logger.debug(
            f"Could not determine base image and version from {last_from}")
        return False, None

    # Check if we already have EOL data for this base image and version
    cache_key = f"{base_image}:{base_version}"
    if cache_key in BASE_EOL_DATES:
        logger.debug(f"Using cached EOL data for {cache_key}")
    else:
        # Query EOL data and cache the result
        is_eol, eol_date = query_endoflife_date(base_image, base_version)
        BASE_EOL_DATES[cache_key] = (is_eol, eol_date)

    return BASE_EOL_DATES[cache_key]


def is_live_version(product, stripped_version):
    """Check if version exists in lifecycle data and is still in maintenance."""
    logger.debug(
        f"Checking if {product} version {stripped_version} is present in "
        "lifecycle data"
    )

    lifecycle_file = os.path.join(
        REPOS_DIR, "product-metadata", product, "lifecycle_dates.json"
    )

    if os.path.exists(lifecycle_file):
        try:
            with open(lifecycle_file) as f:
                lifecycle_data = json.load(f)

            # Get major.minor version
            version_parts = stripped_version.split('.')
            major_minor = f"{version_parts[0]}.{version_parts[1]}"

            if major_minor in lifecycle_data:
                eom_date = lifecycle_data[major_minor].get(
                    'end_of_maintenance')
                if eom_date:
                    # Parse YYYY-MM format
                    eom_year, eom_month = map(int, eom_date.split('-'))
                    # Add 1 month to get start of out-of-maintenance period
                    if eom_month == 12:
                        eom_year += 1
                        eom_month = 1
                    else:
                        eom_month += 1

                    eom_datetime = datetime.datetime(eom_year, eom_month, 1)
                    if eom_datetime <= datetime.datetime.now():
                        logger.debug(f"Version {stripped_version} is out of "
                                     "maintenance")
                        return False
        except Exception as e:
            logger.warning(f"Error reading lifecycle data for {product}: {e}")
    else:
        logger.debug(
            f"No lifecycle data found for {product}, skipping maintenance check"
        )
    # Then check manifest
    manifests = manifest_util.get_metadata_for_products("repos/manifest")

    version_parts = stripped_version.split('.')
    major_minor = f"{version_parts[0]}.{version_parts[1]}"

    for manifest_path, manifest_data in manifests.items():
        if product == manifest_data.get('prod_name'):
            if manifest_data.get('version') in [stripped_version, f"{major_minor}.x"]:
                is_eol, eol_date = base_eol(product, stripped_version)
                if is_eol:
                    # Base image is EOL, but we'll still consider it live if it
                    # wasn't created after the EOL date
                    # Note: we do the comparison against the official
                    # enterprise image, under the assumption that the
                    # community image will be the same
                    image = f"{IMAGES[product]['official']}:enterprise-{stripped_version}"
                    create_date = get_image_create_date(image)

                    if create_date and eol_date:
                        # Convert both dates to datetime objects for comparison
                        eol_datetime = datetime.datetime.strptime(
                            eol_date, "%Y-%m-%d")
                        create_datetime = datetime.datetime.strptime(
                            create_date, "%Y-%m-%d")

                        if create_datetime >= eol_datetime:
                            logger.debug(f"Base image for {product} version {stripped_version} has reached EOL on {eol_date}, "
                                         f"and image was created on or after this date ({create_date}), not considering it live")
                            return False
                        else:
                            logger.debug(f"Base image for {product} version {stripped_version} has reached EOL on {eol_date}, "
                                         f"but image was created before this date ({create_date}), still considering it live")
                            return True
                    else:
                        logger.debug(
                            f"Couldn't compare dates - EOL date: {eol_date}, Create date: {create_date}")
                        # If we can't determine dates, be conservative and assume not live
                        return False
                else:
                    logger.debug(
                        f"Base image for {product} version {stripped_version} has NOT reached EOL")
                    return True

    logger.debug(f"Version {stripped_version} does not exist in manifest")
    return False


def get_image_create_date(image):
    """Get the creation date of a Docker image using skopeo.

    Args:
        image (str): The Docker image reference to inspect.

    Returns:
        str: The creation date of the image in YYYY-MM-DD format, or None if the date couldn't be retrieved.
    """
    logger.debug(f"Getting creation date for image: {image}")
    cmd = ["skopeo", "inspect", "--override-os", "linux",
           "--override-arch", "amd64", f"docker://{image}"]

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)

        if "Created" in data:
            create_date = data["Created"]
            # Parse the ISO format date and convert to YYYY-MM-DD
            parsed_date = datetime.datetime.fromisoformat(
                create_date.replace('Z', '+00:00'))
            formatted_date = parsed_date.strftime('%Y-%m-%d')
            logger.debug(f"Image {image} was created on: {formatted_date}")
            return formatted_date
        else:
            logger.error(f"No creation date found for image {image}")
            return None

    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to inspect image {image}: {e}")
        return None
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse JSON response for image {image}: {e}")
        return None
    except ValueError as e:
        logger.error(f"Failed to parse date from image {image}: {e}")
        return None


def get_architectures(image):
    """Get image architectures."""
    logger.debug(f"Getting architectures for image: {image}")
    cmd = ["docker", "manifest", "inspect", image]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    arches = []

    if result.returncode == 0:
        try:
            data = json.loads(result.stdout)
            if "manifests" in data:
                for manifest in data["manifests"]:
                    arch = manifest["platform"]["architecture"]
                    if arch != "unknown":
                        arches.append("arm64v8" if arch == "arm64" else arch)
            else:
                arches.append("amd64")
        except json.JSONDecodeError:
            logger.error(f"Failed to parse JSON response for image {image}")
            pass
    logger.debug(f"Found architectures: {arches}")
    return sorted(arches)


def get_live_versions(tags, latest_enterprise, latest_community, product):
    """Get dictionary of live versions with their details."""
    logger.info("Identifying live versions...")
    print("Identifying live versions...")
    live_versions = {}
    latest_enterprise_version = Version(latest_enterprise)
    latest_community_version = Version(latest_community)
    logger.debug(f"Latest enterprise version: {latest_enterprise_version}")
    logger.debug(f"Latest community version: {latest_community_version}")

    for tag in tags:
        if tag.startswith("community-"):
            edition = "community"
            stripped_version = tag.replace("community-", "")
        elif tag.startswith("enterprise-"):
            edition = "enterprise"
            stripped_version = tag.replace("enterprise-", "")
        else:
            edition = None
            stripped_version = tag
        logger.debug(f"Processing tag: {tag} (stripped: {stripped_version})")

        try:
            version = Version(stripped_version)
        except ValueError:
            logger.warning(f"Failed to parse version from tag: {tag}")
            continue

        if is_live_version(product, stripped_version):
            if stripped_version not in live_versions:
                logger.debug(f"Adding new version: {stripped_version}")
                live_versions[stripped_version] = {}

            if edition == "enterprise":
                logger.debug(f"Version {stripped_version} is enterprise")
                live_versions[stripped_version]["enterprise"] = True
            elif edition == "community":
                logger.debug(f"Version {stripped_version} is community")
                live_versions[stripped_version]["community"] = True

            if version == latest_enterprise_version:
                logger.debug(
                    f"Version {stripped_version} is latest enterprise")
                live_versions[stripped_version]["latest_enterprise"] = True

            if version == latest_community_version:
                logger.debug(f"Version {stripped_version} is latest community")
                live_versions[stripped_version]["latest_community"] = True

            image = f"{IMAGES[product]['unofficial']}:{tag}"
            live_versions[stripped_version]["architectures"] = get_architectures(
                image)

    logger.debug(f"Found live versions: {live_versions}")
    return live_versions


def last_change_sha(version, edition, product):
    """Get last git commit SHA for a version directory."""
    dir_path = f"{edition}/{product}/{version}"
    logger.debug(f"Getting last commit SHA for {dir_path}")
    try:
        result = subprocess.run(
            ["git", "-C", f"{REPOS_DIR}/docker", "log", "-1",
             "--format=%H", "--date=short", "--", dir_path],
            capture_output=True, text=True, check=True
        )
        sha = result.stdout.strip()
        logger.debug(f"Found SHA: {sha}")
        return sha
    except subprocess.CalledProcessError:
        error_msg = f"No commits found or directory {dir_path} does not exist"
        logger.error(error_msg)
        sys.exit(1)


def add_version(version, tags, edition, architectures, product):
    """Generate version entry text."""
    logger.debug(f"Generating version entry for {version} ({edition})")
    return (
        f"Tags: {', '.join(sorted(tags))}\n"
        f"GitCommit: {last_change_sha(version, edition, product)}\n"
        f"Directory: {edition}/{product}/{version}\n"
        f"Architectures: {', '.join(architectures)}\n\n"
    )


def write_file(body, product):
    """Write output file with header and content."""
    output_path = f"{REPOS_DIR}/dockerhub-official-images/library/" \
        f"{IMAGES[product]['official']}"
    logger.info(f"Writing output file: {output_path}")
    print("Writing output file...")
    with open(output_path, "w") as f:
        f.write(HEADER + body)
    logger.debug("File written successfully")


def push_changes(product, dry_run=False):
    """Push changes to GitHub and create a new branch."""
    repo_path = f"{REPOS_DIR}/dockerhub-official-images"
    branch_name = f"update-official-images-{uuid.uuid4().hex[:8]}"

    logger.info(f"Creating new branch: {branch_name}")
    subprocess.run(
        ["git", "checkout", "-b", branch_name],
        cwd=repo_path,
        check=True
    )

    logger.info("Committing changes")
    subprocess.run(
        ["git", "add", f"library/{IMAGES[product]['official']}"],
        cwd=repo_path,
        check=True
    )
    subprocess.run(
        ["git", "commit", "-m", f"Update {product}"],
        cwd=repo_path,
        check=True
    )

    if dry_run:
        logger.info(
            f"Dry run - would have pushed {product} changes to branch: "
            f"{branch_name} in {repo_path}"
        )
        return False

    logger.info(f"Pushing branch {branch_name} to origin")
    subprocess.run(
        ["git", "push", "origin", branch_name],
        cwd=repo_path,
        check=True
    )

    print(f"Changes pushed to branch: {branch_name}")
    print("Please create a PR from this branch")
    return True


def main():
    parser = argparse.ArgumentParser(
        description='Update official Couchbase Docker images'
    )
    parser.add_argument('product', help='Product name (e.g. couchbase-server)')
    parser.add_argument('latest_enterprise',
                        help='Latest enterprise version number')
    parser.add_argument('latest_community',
                        help='Latest community version number')
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Do not push changes to GitHub'
    )
    args = parser.parse_args()

    if args.dry_run:
        logger.info("Running in dry-run mode - no changes will be pushed")

    logger.info(
        f"Starting update for product: {args.product}, "
        f"latest enterprise version: {args.latest_enterprise}, "
        f"latest community version: {args.latest_community}"
    )

    clone_repos()
    live_versions = get_live_versions(
        get_tags(IMAGES[args.product]['unofficial']),
        args.latest_enterprise,
        args.latest_community,
        args.product
    )

    output = ""
    logger.info("Generating file content...")
    print("Generating file content...")
    for version, details in live_versions.items():
        if details.get("enterprise"):
            logger.debug(f"Processing enterprise version {version}")
            tags = [version, f"enterprise-{version}"]
            if details.get("latest_enterprise"):
                tags.extend(["latest", "enterprise"])
            output += add_version(
                version,
                tags,
                "enterprise",
                details["architectures"],
                args.product
            )

        if details.get("community"):
            logger.debug(f"Processing community version {version}")
            tags = [f"community-{version}"]
            if details.get("latest_community"):
                tags.extend(["community"])
            output += add_version(
                version,
                tags,
                "community",
                details["architectures"],
                args.product
            )

    write_file(output[:-1], args.product)

    logger.debug("Checking for changes in official-images repo")
    result = subprocess.run(
        ["git", "diff", "--exit-code"],
        cwd=f"{REPOS_DIR}/dockerhub-official-images",
        capture_output=True
    )
    if result.returncode == 0:
        logger.info("No changes to dockerhub-official-images repo")
        print("No changes to dockerhub-official-images repo")
    else:
        logger.info("Changes made to dockerhub-official-images repo")
        print("Changes made to dockerhub-official-images repo")
        print(result.stdout.decode())
        if push_changes(args.product, args.dry_run):
            logger.info("Changes pushed to branch, please create a PR")
            sys.exit(1)


if __name__ == "__main__":
    main()
