import logging
import os
import re
from typing import Dict

from src.metadata import image_info
from src.wrappers import manifest, git

logger = logging.getLogger(__name__)


def replace_args(bash_string: str, variables: Dict) -> str:
    """
    Expand variables in a string
    """
    logger.debug(f"Expanding variables in string: {bash_string}")
    pattern = re.compile(r'\$\{?(\w+)\}?')

    def replace_match(match):
        var_name = match.group(1)
        replacement = variables.get(var_name, match.group(0))
        logger.debug(f"Replacing {var_name} with {replacement}")
        return replacement

    result = pattern.sub(replace_match, bash_string)
    logger.debug(f"Expanded string: {result}")
    return result


def dockerfile_path(registry: str, product: str, edition: str, version: str) -> str:
    """
    Finds the dockerfile path on disk for a given product/version/edition/registry
    """
    logger.debug(
        f"Finding Dockerfile path for {product} {edition} {version} on {registry}")
    filename = 'Dockerfile' if registry == 'dockerhub' else 'Dockerfile.rhel'
    repo = image_info(product)['github_repo'].split('/')[-1]

    if repo == "docker":
        if registry == "dockerhub":
            dockerfile = f"repos/docker/{edition}/{product}/{version}/Dockerfile"
            logger.debug(f"Using Docker Hub path: {dockerfile}")
        else:
            # TODO: When we move rhel Dockerfiles into couchbase/docker, we'll
            # need to conditionally reference them here.
            dockerfile = f"repos/redhat-openshift/{product}/Dockerfile"
            if not os.path.exists(dockerfile):
                logger.debug(
                    f"Dockerfile not found at {dockerfile}, trying x64 variant")
                dockerfile = f"repos/redhat-openshift/{product}/Dockerfile.x64"
    else:
        dockerfile = f"repos/{repo}/{image_info(product).get('dockerfiles', {}).get(registry, filename)}"
        if not dockerfile or not os.path.exists(dockerfile):
            logger.debug(
                f"Dockerfile not found at {dockerfile}, falling back to default location")
            dockerfile = f"repos/{repo}/{filename}"

    logger.debug(f"Resolved Dockerfile path: {dockerfile}")

    if os.path.exists(dockerfile):
        return dockerfile
    else:
        logger.error(f"Dockerfile does not exist at {dockerfile}")
        return None


def base_image_from_dockerfile(dockerfile: str) -> str:
    """
    Finds the base image name+tag for a given Dockerfile
    """
    logger.debug(f"Extracting base image from {dockerfile}")
    arg_pattern = r"^\s*ARG\s+([0-9a-zA-Z_]+)=(.*)"
    as_pattern = r"^\s*FROM\s+([^\s]+)\s+AS\s+([^\s]+)"
    from_pattern = r"^\s*FROM\s+([^\s]+)"

    with open(dockerfile, "r") as file:
        images = {}
        args = {}
        for line in file:
            match_arg = re.match(arg_pattern, line, re.IGNORECASE)
            if match_arg:
                args[match_arg.group(1)] = match_arg.group(2)
                logger.debug(
                    f"Found ARG: {match_arg.group(1)}={match_arg.group(2)}")

            match_as = re.match(as_pattern, line, re.IGNORECASE)
            if match_as:
                images[match_as.group(2)] = match_as.group(1)
                logger.debug(
                    f"Found FROM AS: {match_as.group(2)}={match_as.group(1)}")

            match_from = re.match(from_pattern, line)
            if match_from:
                image = replace_args(images.get(
                    match_from.group(1), match_from.group(1)), args)
                logger.debug(f"Found FROM: {image}")

    logger.debug(f"Final base image: {image}")
    return image


def base_image(registry: str, product: str, edition: str,
               version: str, attempt: int = 0) -> str:
    """
    Gets the base image for a given product/version/edition/registry
    """
    logger.debug(
        f"Getting base image for {product} {edition} {version} on {registry} (attempt {attempt})")

    pattern = re.compile(rf'(\d+\.\d+\.\d+)')
    match = re.search(pattern, version)
    if match:
        version = match.group(1)
        logger.debug(f"Normalized version to {version}")

    product_repo = git.repo(image_info(product)['github_repo'])
    if image_info(product)['github_repo'] == "couchbase/docker":
        if registry == "rhcc":
            # For server + sgw, we can just grab the relevant file from the docker
            # repo, however we also need to handle redhat dockerfiles which are
            # in couchbase-partners/redhat-openshift. Best we can really do here
            # is to check out the repo at the last modified time of the equivalent
            # dockerfile in the `docker` repo
            partners_repo = git.repo(
                "ssh://github.com/couchbase-partners/redhat-openshift")
            timestamp = str(os.path.getmtime(
                f"repos/docker/{edition}/{product}/{version}/Dockerfile")).split(".")[0]
            logger.debug(f"Checking out partners repo at timestamp {timestamp}")
            partners_repo.checkout_timestamp(timestamp)
    else:
        release_sha = manifest.revision(product, version)
        logger.debug(f"Checking out product repo at SHA {release_sha}")
        product_repo.checkout(release_sha)

    if attempt == 0:
        dockerfile = dockerfile_path(registry, product, edition, version)
        if dockerfile is None:
            logger.error("No Dockerfile path found")
            return

    image_name = None
    try:
        image_name = base_image_from_dockerfile(dockerfile)
    except FileNotFoundError:
        if attempt == 0:
            logger.debug("Dockerfile not found, retrying with attempt=1")
            image_name = base_image(
                registry, product, edition, version, attempt=1)
        else:
            logger.error(f"FATAL: Couldn't find {dockerfile}")
            exit(1)
    except Exception as e:
        logger.error(f"An error occurred while getting base image: {e}")
        exit(1)

    logger.debug(f"Returning base image: {image_name}")
    return image_name
