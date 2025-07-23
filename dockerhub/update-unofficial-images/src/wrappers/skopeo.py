import json
import logging
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from functools import lru_cache
from time import sleep
from typing import Dict, List, Tuple

from src.wrappers.logging import setup_logging

setup_logging()
logger = logging.getLogger(__name__)


def _timestamp_from_iso(iso_timestamp: str) -> int:
    """
    Convert an ISO timestamp to a unix timestamp
    """
    logger.debug(f"Converting ISO timestamp: {iso_timestamp}")
    cleaned_timestamp = re.sub(
        r'\.[0-9]+', '', iso_timestamp.replace('Z', '+00:00'))
    logger.debug(f"Cleaned timestamp: {cleaned_timestamp}")
    dt = datetime.fromisoformat(cleaned_timestamp)
    dt = dt.replace(tzinfo=timezone.utc)
    timestamp = int(dt.timestamp())
    logger.debug(f"Converted to unix timestamp: {timestamp}")
    return timestamp


class SkopeoCommandError(Exception):
    """Exception raised when a skopeo command fails after all retries"""
    pass


@lru_cache
def _run_cmd(cmd: str, retries: int = 3) -> str:
    """
    Run a command and return stdout
    """
    logger.debug(f"Running command with {retries} retries remaining: {cmd}")
    result = subprocess.run(shlex.split(cmd), text=True, capture_output=True)
    if result.returncode == 0:
        logger.debug(f"Command succeeded, output: {result.stdout}")
        return result.stdout
    else:
        if retries > 0:
            logger.warning(
                f"Command failed with error: {result.stderr}. Retrying in 5s.")
            sleep(5)
            return _run_cmd(cmd, retries - 1)
        else:
            logger.error(
                f"Command failed after all retries: {cmd}. Error: {result.stderr}")
            raise SkopeoCommandError(f"Command failed after all retries: {cmd}. Error: {result.stderr}")


@lru_cache
def tags(image):
    """
    Retrieve all tags for a specified image
    """
    logger.debug(f"Retrieving tags for image: {image}")

    semver_pattern = re.compile(r"(\d+\.\d+\.\d+(-[\w\d]+)?)")

    def extract_semver(text):
        match = semver_pattern.search(text)
        return match.group() if match else ''

    def reverse_sort_by_semver(strings):
        return sorted(strings, key=extract_semver, reverse=True)

    raw_tags = json.loads(_run_cmd(f"skopeo list-tags {image}"))['Tags']
    logger.debug(f"Retrieved {len(raw_tags)} raw tags")

    filtered_tags = [tag for tag in raw_tags if "arm64" not in tag]
    logger.debug(f"Filtered to {len(filtered_tags)} non-arm64 tags")

    sorted_tags = reverse_sort_by_semver(filtered_tags)
    logger.debug(f"Final sorted tags for {image}: {sorted_tags}")
    return sorted_tags


class Image():
    def __init__(self, image: str) -> None:
        logger.debug(f"Initializing Image object for: {image}")
        image_parts = image.split("/")
        image_parts[-1] = image_parts[-1].removeprefix("couchbase-")
        image = "/".join(image_parts)
        logger.debug(f"Normalized image name: {image}")
        self.image = image
        # Get both amd64-specific and raw inspection results
        self.info, self.raw_info = self._inspect(f"{self.image}")
        self.tags = sorted(self.info["RepoTags"])
        self.architectures = self._get_architectures()
        logger.debug(f"Image initialized with {len(self.tags)} tags and architectures: {self.architectures}")

    def create_date(self) -> int:
        """
        Gets the create date of an image
        """
        logger.debug(f"Getting create date for image: {self.image}")
        d = _timestamp_from_iso(self.info["Created"])
        logger.debug(f"Create date for {self.image}: {d}")
        return d

    def _inspect(self, image: str) -> Tuple[Dict, Dict]:
        """
        Inspect an image with Skopeo, returning both amd64-specific and raw inspection results
        """
        logger.debug(f"Inspecting image: {image}")
        try:
            # Get amd64-specific info first
            amd64_result = json.loads(_run_cmd(f"skopeo inspect {image} --override-os linux --override-arch amd64"))
            logger.debug(f"AMD64-specific inspection complete for {image}")

            # Then get raw info for architectures
            raw_result = json.loads(_run_cmd(f"skopeo inspect --raw {image}"))
            logger.debug(f"Raw inspection complete for {image}")

            return amd64_result, raw_result
        except (SystemExit, SkopeoCommandError):
            logger.error(f"Both inspection attempts failed for {image}")
            raise SkopeoCommandError(f"Both inspection attempts failed for {image}")

    def _get_architectures(self) -> List[str]:
        """
        Get list of supported architectures for the image
        """
        logger.debug(f"Getting architectures for image: {self.image}")
        if "manifests" in self.raw_info:
            # This is a multi-arch image (manifest list)
            archs = []
            for manifest in self.raw_info["manifests"]:
                platform = manifest.get("platform", {})
                arch = platform.get("architecture")
                variant = platform.get("variant")
                if arch and variant:
                    archs.append(f"{arch}{variant}")
                elif arch:
                    if arch == "unknown":
                        continue
                    archs.append(arch)
            archs.sort()
        elif "Architecture" in self.raw_info:
            # This is a single-arch image
            arch = self.raw_info["Architecture"]
            variant = self.raw_info.get("Variant")
            if variant:
                archs = [f"{arch}{variant}"]
            else:
                archs = [arch]
        else:
            archs = ["amd64"]
        logger.debug(f"Found architectures for {self.image}: {archs}")
        return archs
