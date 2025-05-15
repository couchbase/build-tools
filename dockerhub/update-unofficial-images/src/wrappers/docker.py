import logging
import subprocess
import time
from typing import List, Tuple

logger = logging.getLogger(__name__)


def pull_image(image_uri: str, max_retries: int = 3) -> None:
    """
    Pull an image with retry logic to handle transient failures.

    Args:
        image_uri: Full image URI to pull
        max_retries: Maximum number of retry attempts

    Raises:
        RuntimeError: If the image pull fails after all retries
    """
    retry_delay = 3  # seconds

    for attempt in range(1, max_retries + 1):
        try:
            logger.debug(
                f"Pulling image (attempt {attempt}/{max_retries}): {image_uri}")
            subprocess.run(
                ["docker", "pull", image_uri],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            )
            logger.debug(
                f"Successfully pulled {image_uri} on attempt {attempt}")
            return
        except subprocess.CalledProcessError as e:
            logger.warning(
                f"Failed to pull {image_uri} (attempt {attempt}/{max_retries}): {e}")
            if attempt < max_retries:
                logger.debug(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
                retry_delay *= 2  # Exponential backoff
            else:
                logger.error(
                    f"Failed to pull {image_uri} after {max_retries} attempts")
                raise RuntimeError(
                    f"Failed to pull image {image_uri} after {max_retries} attempts") from e


def start_container(image_uri: str) -> str:
    """
    Start a container

    Args:
        image_uri: Docker image URI to run

    Returns:
        str: Container ID if successful

    Raises:
        RuntimeError: If container couldn't be started
    """
    try:
        logger.debug(f"Starting container with sh entrypoint: {image_uri}")
        container_id = subprocess.check_output(
            ["docker", "run", "-d", "--entrypoint",
                "sh", image_uri, "-c", "sleep 3600"],
            text=True, stderr=subprocess.PIPE
        ).strip()
        return container_id
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to start container for {image_uri}: {e}")
        raise RuntimeError(f"Failed to start container for {image_uri}") from e


def remove_container(container_id: str) -> None:
    """Remove a container"""
    logger.debug(f"Removing container: {container_id}")
    subprocess.run(
        ["docker", "rm", "-f", container_id],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )


def _check_package_manager_exists(container_id: str, pkg_mgr: str) -> bool:
    """
    Check if a specific package manager exists in the container.

    Args:
        container_id: Docker container ID
        pkg_mgr: Package manager to check for

    Returns:
        bool: True if package manager exists, False otherwise
    """
    command_result = subprocess.run(
        ["docker", "exec", "--user", "0", container_id,
            "sh", "-c", f"command -v {pkg_mgr}"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )

    return command_result.returncode == 0


def _run_apt_update(container_id: str) -> None:
    """
    Run apt update in the container.

    Args:
        container_id: Docker container ID

    Raises:
        RuntimeError: If apt update fails
    """
    try:
        logger.debug("Running apt update first")
        subprocess.run(
            ["docker", "exec", "--user", "0",
                container_id, "apt", "update", "-qq"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            check=True
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to run apt update: {e}")
        raise RuntimeError(f"Failed to run apt update: {e.stderr}") from e


def _run_apk_update(container_id: str) -> None:
    """
    Run apk update in the container.

    Args:
        container_id: Docker container ID

    Raises:
        RuntimeError: If apk update fails
    """
    try:
        logger.debug("Running apk update first")
        subprocess.run(
            ["docker", "exec", "--user", "0",
                container_id, "apk", "update", "-q"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            check=True
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to run apk update: {e}")
        raise RuntimeError(f"Failed to run apk update: {e.stderr}") from e


def _execute_package_update_check(container_id: str, pkg_mgr: str, check_cmd: str) -> subprocess.CompletedProcess:
    """
    Run package check command in the container.

    Args:
        container_id: Docker container ID
        pkg_mgr: Package manager name
        check_cmd: Command to check for package updates

    Returns:
        subprocess.CompletedProcess: Result of the command

    Raises:
        RuntimeError: If command fails (except for yum/dnf with code 100)
    """
    logger.debug(f"Running package check: {check_cmd}")
    check_result = subprocess.run(
        ["docker", "exec", "--user", "0",
            container_id, "sh", "-c", check_cmd],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )

    # Handle yum/dnf where return code 100 means updates available
    if pkg_mgr in ["yum", "dnf"] and check_result.returncode == 100:
        logger.debug(f"Package manager {pkg_mgr} returned 100, updates are available")

    # All other non-zero return codes are errors
    elif check_result.returncode != 0:
        error_msg = (
            f"Package check command '{check_cmd}' failed for {pkg_mgr}\n"
            f"Return code: {check_result.returncode}\n"
            f"Error: {check_result.stderr}"
        )
        logger.error(error_msg)
        raise RuntimeError(f"Failed to check for package updates: {error_msg}")

    return check_result


def _parse_apt_updates(output: str) -> List[str]:
    """Parse apt package updates."""
    packages = []
    for line in output.strip().split('\n'):
        if line and not line.startswith("Listing..."):
            package_name = line.split('/')[0]
            packages.append(package_name)
    return packages


def _parse_yum_dnf_updates(output: str) -> List[str]:
    """Parse yum/dnf package updates."""
    packages = []
    for line in output.strip().split('\n'):
        if line and not line.startswith(("Loaded plugins", "Last metadata")):
            parts = line.split()
            if len(parts) >= 1:
                packages.append(parts[0])
    return packages


def _parse_microdnf_updates(output: str) -> List[str]:
    """Parse microdnf package updates."""
    packages = []
    in_package_section = False
    section_headers = ("Installing:", "Upgrading:", "Reinstalling:",
                      "Obsoleting:", "Removing:", "Downgrading:")

    for line in output.strip().split('\n'):
        line = line.strip()
        if not line:
            continue

        # Check if we're entering a new package section
        if line.startswith(section_headers):
            in_package_section = True
            continue
        elif line.startswith("Transaction Summary:"):
            in_package_section = False
            continue

        # Extract package names from any sections showing changes
        if in_package_section and not line.startswith(' replacing'):
            # Extract package name from something like: " package_name-version.arch ..."
            parts = line.strip().split('-', 1)
            if parts and parts[0].strip():
                package_name = parts[0].strip()
                packages.append(package_name)

    return packages


def _parse_apk_updates(output: str) -> List[str]:
    """Parse apk package updates."""
    packages = []
    for line in output.strip().split('\n'):
        if "upgradable from" in line:
            package_name = line.split()[0]
            packages.append(package_name)
    return packages


def check_container_for_updates(container_id: str) -> Tuple[bool, List[str]]:
    """
    Check which package manager is available and if updates are needed.

    Args:
        container_id: Docker container ID to check

    Returns:
        Tuple[bool, List[str]]: (updates_needed, packages_to_update)
        If no package manager or root user are found, returns (False, [])

    Raises:
        RuntimeError: If package checks fail
    """

    package_managers = {
        "apt": "apt list --upgradable -qq",
        "yum": "yum check-update --quiet",
        "dnf": "dnf check-update --quiet",
        "microdnf": "microdnf upgrade --assumeno",
        "apk": "apk -v upgrade --available --simulate"
    }

    packages_to_update = []
    package_manager_found = False

    for pkg_mgr, check_cmd in package_managers.items():
        logger.debug(f"Checking if {pkg_mgr} is available in the container")

        try:
            # Check if package manager exists
            if not _check_package_manager_exists(container_id, pkg_mgr):
                continue

            # We found a package manager
            logger.debug(f"Found package manager: {pkg_mgr}")
            package_manager_found = True

            # For apt, we need to run update first
            if pkg_mgr == "apt":
                _run_apt_update(container_id)
            # For apk, we need to run update first
            elif pkg_mgr == "apk":
                _run_apk_update(container_id)

            # Run the package check command
            check_result = _execute_package_update_check(container_id, pkg_mgr, check_cmd)

            # Parse output according to package manager
            if pkg_mgr == "apt":
                packages_to_update = _parse_apt_updates(check_result.stdout)
            elif pkg_mgr in ["yum", "dnf"]:
                if check_result.returncode == 100:  # Updates available
                    packages_to_update = _parse_yum_dnf_updates(check_result.stdout)
            elif pkg_mgr == "microdnf":
                packages_to_update = _parse_microdnf_updates(check_result.stdout)
            elif pkg_mgr == "apk":
                packages_to_update = _parse_apk_updates(check_result.stdout)

            # If we found a package manager and ran the check, we're done
            break
        except RuntimeError as e:
            raise

    if not package_manager_found:
        logger.warning("No supported package manager found in the container")
        return False, []  # Return no updates needed instead of raising an error

    return len(packages_to_update) > 0, packages_to_update


def check_image_for_updates(image_uri: str) -> Tuple[bool, List[str]]:
    """
    Check if the image has any packages that need to be updated.

    Args:
        image_uri: Full Docker image URI to check

    Returns:
        Tuple[bool, List[str]]: (updates_needed, package_list)
        If no package manager is found, returns (False, [])

    Raises:
        RuntimeError: If image pull or container start fails
        RuntimeError: If apt update fails for containers using apt
    """
    logger.debug(f"Checking for package updates in {image_uri}")
    container_id = None

    try:
        # Pull the image - will raise exception on failure
        pull_image(image_uri)

        # Start container - will raise exception on failure
        container_id = start_container(image_uri)

        # Check for updates - will raise exception if issues occur
        updates_needed, packages_to_update = check_container_for_updates(container_id)

        logger.debug(f"Package updates needed: {updates_needed}")
        if updates_needed:
            logger.debug(f"Packages to update: {packages_to_update}")

        return updates_needed, packages_to_update
    finally:
        # Clean up
        if container_id:
            try:
                remove_container(container_id)
            except Exception as e:
                logger.warning(
                    f"Error cleaning up container {container_id}: {str(e)}")
