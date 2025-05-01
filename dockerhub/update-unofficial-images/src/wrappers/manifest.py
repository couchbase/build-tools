import logging
import xml.etree.ElementTree as ET

from src.metadata import image_info

logger = logging.getLogger(__name__)


def revision(product: str, version: str) -> str:
    """Get the SHA for a specified product+version from its release manifest."""
    logger.debug(f"Getting revision for {product} version {version}")

    manifest_path = f'repos/manifest/released/{product}/{version}.xml'
    logger.debug(f"Looking for manifest at {manifest_path}")

    try:
        tree = ET.parse(manifest_path)
        logger.debug("Successfully parsed manifest XML")
    except FileNotFoundError as e:
        logger.error(f"Release manifest not found: {manifest_path}")
        return ""
    except ET.ParseError as e:
        logger.error(f"Failed to parse manifest XML: {e}")
        return ""

    root = tree.getroot()
    repo_name = image_info(product)['github_repo'].split("/")[-1]
    logger.debug(f"Looking for project with name {repo_name}")

    for project in root.findall('project'):
        if project.get('name') == repo_name:
            revision = project.get('revision')
            logger.debug(f"Found revision {revision} for {product}/{version}")
            return revision

    logger.error(f"No project named {repo_name} found in {manifest_path}")
    return ""
