import json
import logging
import os
import re
import requests
import tempfile
from datetime import datetime
from typing import Dict, List, Tuple, Optional

from src.metadata import image_info, lifecycle_dates, REGISTRIES
from src.wrappers import skopeo
from src.wrappers.skopeo import SkopeoCommandError
from src.wrappers.dockerfile import base_image
from src.wrappers.collections import defaultdict
from src.wrappers.docker import check_image_for_updates

logger = logging.getLogger(__name__)

semver_pattern = r'([0-9]+\.[0-9]+\.[0-9]+)'

# Cache for floating tag digests to avoid repeated inspections
# Key format: f"{registry}:{product}:{tag}"
_floating_tag_digest_cache = {}


def filter_versions(versions: List[str] = [],
                    product: str = None) -> List[str]:
    """
    Filters out versions that have reached end of maintenance according to
    lifecycle dates.
    """
    logger.debug(f"Filtering versions for product {product}: {versions}")
    if not product:
        logger.debug("No product specified, returning unfiltered versions")
        return versions

    filtered_versions = []
    current_date = datetime.now().strftime("%Y-%m")
    logger.debug(f"Current date: {current_date}")

    for version in versions:
        match = re.search(r'(\d+\.\d+\.\d+)', version)
        if match:
            semver = match.group(1)
            version_parts = semver.split(".")
            major = version_parts[0]
            major_minor = ".".join(version_parts[:2])
            logger.debug(
                f"Processing version {version} (semver: {semver}, major: {major},"
                f" major.minor: {major_minor})")

            # Get lifecycle dates for this version - check major.minor.patch,
            # major.minor and major
            dates = lifecycle_dates(product)

            end_of_maintenance = (
                dates.get(semver, {}).get("end_of_maintenance") or
                dates.get(major_minor, {}).get("end_of_maintenance") or
                dates.get(major, {}).get("end_of_maintenance")
            )
            logger.debug(
                f"End of maintenance date for {semver}: {end_of_maintenance}")

            # Include version if no date or date is in the future
            if not end_of_maintenance or end_of_maintenance > current_date:
                logger.debug(f"Including version {version}")
                filtered_versions.append(version)
            else:
                logger.debug(
                    f"Excluding version {version} - end of maintenance reached")

    logger.debug(f"Filtered versions: {filtered_versions}")
    return filtered_versions


def image_uri(registry, product):
    logger.debug(f"Generating image URI for {product} on {registry}")
    namespace = "couchbase/" if image_info(product) else ""
    if namespace:
        uri = (f"docker://{REGISTRIES[registry]['FQDN']}/{namespace}"
               f"{product.removeprefix('couchbase-').removeprefix('couchbase/')}")
    else:
        uri = f"docker://{product}"
    logger.debug(f"Generated URI: {uri}")
    return uri


def is_absent(registry, product, edition):
    """
    Determine whether a product/edition is absent from a specified registry.
    """
    logger.debug(
        f"Checking if {product} ({edition}) is absent from {registry}")

    absent = False
    for absence in image_info(product).get("absences", []):
        if "registry" in absence and absence['registry'] == registry:
            if absence.get('edition', edition) == edition:
                absent = True
        if "edition" in absence and absence['edition'] == edition:
            if absence.get('registry', registry) == registry:
                absent = True

    logger.debug(
        f"{product}-{edition} is{' ' if absent else ' not '} absent from "
        f"{registry}")
    return absent


def redhat_tags(product: str, edition: str) -> dict:
    """
    Get all the tags associated with a given product+edition on rhcc.
    """
    logger.debug(f"Getting RedHat tags for {product}-{edition}")

    if is_absent("rhcc", product, edition):
        logger.debug("Product/edition is absent from RHCC")
        return defaultdict()

    try:
        # Regex to capture semver (X.Y.Z) and an optional build number (-N)
        # Group 1: X.Y.Z (e.g., "1.2.3")
        # Group 2 (optional): N (e.g., "10" from "-10")
        semver_build_pattern = re.compile(r'^(\d+\.\d+\.\d+)(?:-(\d+))?$')

        # Temporary storage for candidate tags, grouped by base semver
        # Key: "X.Y.Z", Value: list of (build_number_int, full_tag_string)
        # build_number_int is -1 for plain "X.Y.Z" tags, otherwise the parsed integer.
        semver_candidates = defaultdict(list)

        tags = skopeo.tags(image_uri("rhcc", product))
        logger.debug(f"Found {len(tags)} total tags from skopeo for {product}")

        for tag_str in tags:
            match = semver_build_pattern.match(tag_str)
            if match:
                base_semver = match.group(1)  # The "X.Y.Z" part
                build_num_str = match.group(2) # The "N" part (string or None)

                if build_num_str:
                    try:
                        build_number = int(build_num_str)
                    except ValueError:
                        logger.warning(
                            f"Could not parse build number from tag {tag_str} for product {product}, skipping.")
                        continue
                else:
                    # Tag is like "1.2.3", no build number suffix.
                    # Assign a value that sorts it lower than actual positive build numbers.
                    build_number = -1

                semver_candidates[base_semver].append((build_number, tag_str))

        filtered_tags = defaultdict()
        for base_semver, candidates in semver_candidates.items():
            if not candidates:
                continue

            # Sort candidates:
            # Primary key: build_number (descending, so highest actual build number is first).
            # A build_number of -1 (for plain semver X.Y.Z) will come after any positive build numbers.
            candidates.sort(key=lambda x: x[0], reverse=True)

            # The best tag is the first one after sorting
            best_tag_full_string = candidates[0][1]
            filtered_tags[best_tag_full_string] = defaultdict()
            logger.debug(
                f"For product {product}, selected tag for base semver {base_semver}: {best_tag_full_string} from candidates: {candidates}")

        logger.debug(f"Returning {len(filtered_tags)} filtered tags for {product}")
        return filtered_tags

    except SkopeoCommandError as e:
        logger.error(f"Failed to get RedHat tags for {product}-{edition}: {e}")
        logger.info(f"Returning empty tag list for {product}-{edition} on rhcc")
        return defaultdict()


def docker_tags(product: str, edition: str) -> Dict:
    """
    Get all the tags associated with a given product+edition on dockerhub.
    """
    logger.debug(f"Getting Docker Hub tags for {product}-{edition}")

    if is_absent("dockerhub", product, edition):
        logger.debug("Product/edition is absent from Docker Hub")
        return defaultdict()

    try:
        versions = skopeo.tags(image_uri("dockerhub", product))
        logger.debug(f"Found {len(versions)} total tags")

        filtered_versions = defaultdict()

        # We just grab whatever tags are there for server-sandbox
        if product == "server-sandbox":
            logger.debug("Processing server-sandbox tags")
            filtered_versions = {version: defaultdict() for version in versions}

        # for sgw and server, we can discover for a specified edition based on
        # prefix/suffix
        elif product in ["couchbase-server", "sync-gateway"]:
            logger.debug("Processing server/sync-gateway tags")
            pattern = re.compile(rf'^({edition}\-)?(\d+\.\d+\.\d+)(\-{edition})?$')
            for version in versions:
                if (match := pattern.match(version)) and (edition in version):
                    tag = "".join([m for m in match.groups() if m is not None])
                    filtered_versions[tag] = defaultdict()
                    logger.debug(f"Added tag {tag}")

        # For anything else (CND) we're just looking for semvers
        else:
            logger.debug("Processing generic semver tags")
            pattern = re.compile(rf'^(\d+\.\d+\.\d+)$')
            filtered_versions = {
                match.group(1): defaultdict() for version in versions if (
                    match := pattern.match(version))}

        logger.debug(f"Returning {len(filtered_versions)} filtered tags")
        return filtered_versions

    except SkopeoCommandError as e:
        logger.error(f"Failed to get Docker Hub tags for {product}-{edition}: {e}")
        logger.info(f"Returning empty tag list for {product}-{edition} on dockerhub")
        return defaultdict()


def github_tags(product: str, edition: str) -> Dict:
    """
    Get a list of product+edition versions for specific edition of a product
    in couchbase/docker.
    """
    logger.debug(f"Getting GitHub tags for {product}{edition}")

    try:
        path = f"repos/docker/{edition}/{product}"
        dirs = sorted(os.listdir(path))
        logger.debug(f"Found {len(dirs)} directories in {path}")
        return {v: defaultdict() for v in dirs}
    except FileNotFoundError:
        logger.debug(f"Directory not found: {path}")
        return defaultdict()


def get_product_tags(registries: List[str],
                     product: str,
                     edition: str) -> Dict:
    """
    Get all rhcc+github+dockerhub tags (eol filtered) for a given edition of
    a product.
    """
    logger.debug(
        f"Getting product tags for {product} {edition} on registries: "
        f"{registries}")

    tags = defaultdict()
    if edition in image_info(product)['editions']:
        if "dockerhub" in registries:
            logger.debug("Getting Docker Hub tags")
            tags["dockerhub"] = docker_tags(product, edition)
        if "rhcc" in registries:
            logger.debug("Getting RedHat tags")
            tags["rhcc"] = redhat_tags(product, edition)

        logger.debug("Getting GitHub tags")
        tags["github"] = github_tags(product, edition)

        for registry in tags:
            logger.debug(f"Filtering versions for {registry}")
            tags[registry] = filter_versions(tags[registry], product=product)

    logger.debug(f"Returning tags: {tags}")
    return tags


def get_floating_tags(registry: str, product: str, tag: str, image_info=None) -> List[str]:
    """
    Identify floating tags (enterprise, community, latest) that point
    to the same image as the specified semver tag.

    Accepts optional image_info parameter to avoid re-inspecting the image.
    """
    logger.debug(
        f"Checking for floating tags for {product}:{tag} on {registry}")

    # Floating tags we want to track
    floating_tags = ["enterprise", "community", "latest"]
    matches = []

    # Get the digest of the current tag
    uri = image_uri(registry, product)
    target_digest = None

    # Use provided image_info if available
    if image_info:
        target_digest = image_info.raw_info.get(
            "digest") or image_info.info.get("Digest")
    else:
        # Create a new Image object if we don't have the info
        image = skopeo.Image(f"{uri}:{tag}")
        target_digest = image.raw_info.get(
            "digest") or image.info.get("Digest")

    if not target_digest:
        logger.warning(f"Could not get digest for {uri}:{tag}")
        return []

    # Get available tags to check which of the floating tags exist
    available_tags = skopeo.tags(uri)
    logger.debug(f"Found {len(available_tags)} available tags for {uri}")

    # Filter floating tags to only include ones that exist
    existing_floating_tags = [
        ft for ft in floating_tags if ft in available_tags]
    if existing_floating_tags:
        logger.debug(f"Found existing floating tags: {existing_floating_tags}")
    else:
        logger.debug("No floating tags found")
        return []

    # Check each floating tag to see if it matches
    for floating_tag in existing_floating_tags:
        # Create cache key for this floating tag
        cache_key = f"{registry}:{product}:{floating_tag}"
        float_digest = None

        # Try to get digest from cache first
        if cache_key in _floating_tag_digest_cache:
            float_digest = _floating_tag_digest_cache[cache_key]
            logger.debug(f"Using cached digest for {floating_tag}")
        else:
            float_image = skopeo.Image(f"{uri}:{floating_tag}")
            float_digest = float_image.raw_info.get(
                "digest") or float_image.info.get("Digest")

            # Cache the digest for future use
            if float_digest:
                _floating_tag_digest_cache[cache_key] = float_digest
                logger.debug(f"Cached digest for {floating_tag}")

        if float_digest and float_digest == target_digest:
            matches.append(floating_tag)
            logger.debug(
                f"Floating tag '{floating_tag}' points to the same image as '{tag}'")

    return matches


def get_base_image_and_dates(registry: str,
                             product: str,
                             edition: str,
                             tag: str) -> Dict:
    """
    Get a dict containing base image name + create dates of an image and its
    base.
    """
    logger.debug(
        f"Getting base image and dates for {product}-{edition}:{tag} on "
        f"{registry}")

    base = base_image(registry, product, edition, tag)
    logger.debug(f"Found base image: {base}")

    if (base == "scratch" or
        "distroless" in base or
        "alpine:scratch" in base
            or base.startswith("busybox:")):
        base_created = 0
        product_created = 0
        rebuild_needed = False
        architectures = []
        logger.debug(f"Distroless base image: {base}, no rebuild needed")
        return {"rebuild_needed": False, "distroless": True}
    else:
        [base_name, base_tag] = (base.split(":")
                                 if ":" in base else [base, "latest"])

        logger.debug(f"Getting product created date for {product}:{tag}")
        product_image = skopeo.Image(f"{image_uri(registry, product)}:{tag}")
        product_created = product_image.create_date()
        architectures = product_image.architectures

        logger.debug(f"Getting base created date for {base_name}:{base_tag}")
        base_image_obj = skopeo.Image(
            f"{image_uri(registry, base_name)}:{base_tag}")
        base_created = base_image_obj.create_date()
        rebuild_needed = product_created - base_created < 0
        logger.debug(
            f"Product created: {product_created}, Base created: {base_created}, "
            f"Rebuild needed: {rebuild_needed}")

    # Get build job for this product and registry
    build_job = None
    if product_info := image_info(product):
        build_job = product_info.get("build_jobs", {}).get(registry)
        logger.debug(
            f"Retrieved build job for {product} on {registry}: {build_job}")

    # Check if this tag is associated with any floating tags
    # Pass the already-inspected product_image
    floating_tags = get_floating_tags(registry, product, tag,
                                      image_info=product_image if 'product_image' in locals() else None)

    return {
        "base_image": base,
        "base_created": base_created,
        "product_created": product_created,
        "rebuild_needed": rebuild_needed,
        "architectures": architectures,
        "registry": registry,
        "build_job": build_job,
        "floating_tags": floating_tags,
        "distroless": False
    }


def format_time_difference(total_seconds):
    """Format a time difference in seconds to a human-readable string."""
    if total_seconds < 60:
        return f"{int(total_seconds)} seconds"
    elif total_seconds < 3600:
        return f"{int(total_seconds/60)} minutes"
    elif total_seconds < 86400:
        return f"{int(total_seconds/3600)} hours"
    elif total_seconds < 604800:
        return f"{int(total_seconds/7)} days"
    else:
        return f"{int(total_seconds/(7*24*3600))} weeks"


def has_norebuild_file(product: str, version: str) -> bool:
    """
    Check if a .norebuild file exists for the specified product/version.
    """
    url = f"http://releases.service.couchbase.com/builds/releases/{product}/{version}/.norebuild"
    logger.debug(f"Checking for .norebuild file at {url}")

    try:
        response = requests.head(url, timeout=10)
        # It's OK for a .norebuild file to not exist
        if response.status_code == 404:
            logger.debug(
                f".norebuild file does not exist for {product}/{version}")
            return False
        # Norebuild file exists
        elif response.status_code == 200:
            logger.debug(f".norebuild file exists for {product}/{version}")
            return True
        # Any other status code is unexpected and should be fatal
        else:
            logger.error(
                f"Unexpected status code {response.status_code} when checking for .norebuild file")
            raise requests.exceptions.HTTPError(
                f"Unexpected status code: {response.status_code}")
    except requests.RequestException as e:
        # Fatal if we can't access releases.service.couchbase.com at all
        logger.error(
            f"Fatal error accessing releases.service.couchbase.com: {e}")
        raise


def process_single_tag(registry, product, edition, semver, tag):
    """
    Process a single tag and return its metadata.

    Follows these steps in order:
    1. Check if .norebuild file exists (skip if yes)
    2. Check if base image is newer (rebuild if yes)
    3. Check for package updates (rebuild if updates in product image
       which are not available in base image)
    """
    tag_data = {'queried_tag': tag, 'rebuild_needed': False, 'processing_failed': False}

    try:
        # STEP 1: Check for .norebuild file
        if has_norebuild_file(product, semver):
            logger.info(
                f"Skipping rebuild for {product}/{semver} on {registry} due to .norebuild file")
            tag_data['skipped_reason'] = ".norebuild file"
            return tag_data

        # STEP 2: Check if base image is newer
        logger.debug(f"Checking if base image is newer for {product}/{semver}")
        tag_data.update(get_base_image_and_dates(registry, product, edition, tag))

        if tag_data['rebuild_needed']:
            if 'base_created' in tag_data and 'product_created' in tag_data:
                if tag_data['base_created'] > tag_data['product_created']:
                    logger.info(
                        f"Rebuild needed for {registry}/{product}/{edition}/{semver}: "
                        f"Base image {tag_data['base_image']} is newer")
            return tag_data

        # Skip package checks for distroless images
        distroless = tag_data.get('distroless', False)
        if distroless:
            logger.debug(f"Skipping package update check for {product}/{semver} (distroless image)")
            return tag_data

        # STEP 3: Check for package updates
        update_data = check_package_updates(registry, product, semver, tag, tag_data)
        tag_data.update(update_data)

        return tag_data

    except SkopeoCommandError as e:
        logger.error(f"Skopeo command failed for {registry}/{product}/{edition}/{semver}: {e}")
        logger.info(f"Continuing with next image")
        tag_data['processing_failed'] = True
        tag_data['skipped_reason'] = f"skopeo command failed: {str(e)}"
        return tag_data
    except Exception as e:
        logger.error(f"Unexpected error processing {registry}/{product}/{edition}/{semver}: {e}")
        logger.info(f"Continuing with next image")
        tag_data['processing_failed'] = True
        tag_data['skipped_reason'] = f"unexpected error: {str(e)}"
        return tag_data


def check_package_updates(registry, product, semver, tag, tag_data):
    """
    Check for package updates in product and base images.

    Args:
        registry: The container registry
        product: The product name
        semver: The semantic version
        tag: The image tag to check
        tag_data: Existing tag data with base image information

    Returns:
        Dict with update information
    """
    update_data = {}
    try:
        uri = image_uri(registry, product).replace("docker://", "")
        full_uri = f"{uri}:{tag}"

        # Check if our product image needs package updates
        product_updates_needed, product_packages = check_image_for_updates(
            full_uri, image_label="product image")

        # If no updates needed in our image, we're done
        if not product_updates_needed:
            logger.debug(f"No package updates needed for {product}/{semver}")
            return update_data

        # Updates available in product image - compare against base image
        logger.info(f"Found package updates in {product}/{semver}, checking base image")

        # Check base image for same updates
        try:
            base_image_name = tag_data.get('base_image')
            logger.debug(f"Checking base image {base_image_name} for package updates")
            base_updates_needed, base_packages = check_image_for_updates(
                base_image_name, image_label="base image")

            # If base image has updates, compare the packages
            if not base_updates_needed:
                # Base has no updates but our image does, rebuild
                logger.info(f"Rebuild needed for {product}/{semver}: base image has no updates but our image does")
                update_data['rebuild_needed'] = True
                update_data['packages_to_update'] = product_packages
            else:
                # Product and base have updates, compare the packages
                product_updates_set = set(product_packages)
                base_updates_set = set(base_packages)

                # If product image has unique updates, rebuild is needed
                updates_only_in_product = product_updates_set - base_updates_set
                if updates_only_in_product:
                    logger.info(
                        f"Rebuild needed for {product}/{semver}: "
                        f"product-specific package updates required: {list(updates_only_in_product)}")
                    update_data['rebuild_needed'] = True
                    update_data['packages_to_update'] = list(updates_only_in_product)
                elif product_updates_set: # Implies product_updates_set is a non-empty subset of or equal to base_updates_set
                    logger.info(
                        f"Ineffective rebuild for {product}/{semver}: "
                        f"all product package updates ({list(product_updates_set)}) are also present in base image updates.")
                    update_data['rebuild_ineffective'] = True
                    update_data['packages_in_common'] = list(product_updates_set)


        except Exception as e:
            # Fallback to rebuilding if base image check fails
            logger.warning(f"Error checking base image packages: {e}")
            update_data['rebuild_needed'] = True
            update_data['packages_to_update'] = product_packages
    except Exception as e:
        logger.warning(f"Error in package update checking process: {e}")
        # On any other error, assume no updates needed
        logger.info(f"Assuming no updates needed for {product}/{semver} due to error in update process")

    return update_data


def process_product_edition(registries, product, edition, versions=None):
    """Process all tags for a specific product/edition combination."""
    results = defaultdict()
    product_tags = get_product_tags(registries, product, edition)
    tag_count = 0
    rebuild_count = 0

    for registry in product_tags:
        if registry in registries:
            if registry not in results:
                results[registry] = defaultdict()
            if product not in results[registry]:
                results[registry][product] = defaultdict()
            if edition not in results[registry][product]:
                results[registry][product][edition] = defaultdict()

            for tag in product_tags[registry]:
                if not versions or any([v in tag for v in versions]):
                    tag_count += 1
                    logger.debug(f"Processing tag: {tag}")
                    semver = re.search(semver_pattern, tag).group(1)

                    tag_data = process_single_tag(
                        registry, product, edition, semver, tag)
                    results[registry][product][edition][semver] = tag_data

                    if tag_data['rebuild_needed']:
                        rebuild_count += 1
                else:
                    logger.debug(f"Skipping tag: {tag} - not in versions")
        else:
            logger.debug(f"Skipping registry: {registry} - not in registries")

    return results, tag_count, rebuild_count


def analyze_images(registries: List[str],
                   products: List[str],
                   editions: List[str],
                   versions: List[str] = None) -> Dict:
    """
    Retrieve info for any number of registries, products, editions and versions.

    Retrieved info is structured in a dictionary with relevant metadata being
    stored for each registry/product/edition/version:
    {
      [registry...]: {
        [product...]: {
          [edition...]: {
            [version...]: {
              "base_image": [image:tag],
              "base_created": [timestamp],
              "product_created": [timestamp],
              "rebuild_needed": [bool],
              "queried_tag": [image:tag],
              "architectures": [list],
              "registry": [registry_name],
              "build_job": [job_name]
            }
          }
        }
      }
    }
    """
    logger.debug(
        f"Analyzing images for registries: {registries}, products: {products}, "
        f"editions: {editions}, versions: {versions}")

    tags = defaultdict()
    for product in products:
        logger.debug(f"Processing product: {product}")
        total_product_tags = 0
        base_updates_available = 0

        for edition in editions:
            logger.debug(f"Processing edition: {edition}")
            edition_results, tag_count, rebuild_count = process_product_edition(
                registries, product, edition, versions)

            # Merge results
            for registry in edition_results:
                if registry not in tags:
                    tags[registry] = defaultdict()

                for prod in edition_results[registry]:
                    if prod not in tags[registry]:
                        tags[registry][prod] = defaultdict()

                    for ed in edition_results[registry][prod]:
                        tags[registry][prod][ed] = edition_results[registry][prod][ed]

            total_product_tags += tag_count
            base_updates_available += rebuild_count

        if total_product_tags > 0:
            logger.info(
                f"Processed {total_product_tags} tags for {product} ({base_updates_available} base image updates available)")

    logger.debug(f"Analysis complete - processed {len(tags)} tags")
    return tags
