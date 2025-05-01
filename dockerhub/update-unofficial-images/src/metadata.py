import json
import logging
import os
from functools import lru_cache

from src.wrappers.logging import setup_logging

setup_logging()
logger = logging.getLogger(__name__)

REGISTRIES = {
    "dockerhub": {
        "FQDN": "docker.io",
    },
    "rhcc": {
        "FQDN": "registry.connect.redhat.com",
    }
}


def all_products():
    # all_products is a list of strings containing the names of each handled
    # product. Inclusion is dictated by the presence of containers/image_info.json
    # in the product directory in product-metadata.
    logger.debug("Building list of all products from product-metadata repo")

    products = []
    for root, dirs, files in os.walk(f"repos/product-metadata/"):
        json_path = os.path.join(root, "containers", "image_info.json")
        if os.path.isfile(json_path):
            # Fix SGW
            product = root.split('/')[-1].replace("_", "-")
            if product == "couchbase/server":
                product = "couchbase-server"
            products.append(product)
            logger.debug(f"Added product: {product}")
    return products


@lru_cache
def image_info(product):
    logger.debug(f"Getting image info for product: {product}")
    try:
        if product == "sync-gateway":
            product = "sync_gateway"
            logger.debug("Converted sync-gateway to sync_gateway for file lookup")
        if product == "couchbase/server":
            product = "couchbase-server"
            logger.debug("Converted couchbase/server to couchbase-server for file lookup")
        json_path = f"repos/product-metadata/{product}/containers/image_info.json"
        logger.debug(f"Reading image info from: {json_path}")
        with open(json_path) as f:
            info = json.load(f)
            if "editions" not in info:
                logger.debug(
                    f"No editions found for {product}, defaulting to ['default']")
                info['editions'] = ['default']
            logger.debug(f"Successfully retrieved image info for {product}: {info}")
            return info
    except Exception as e:
        logger.debug(f"Failed to get image info for {product}: {str(e)}")
        return {}


@lru_cache
def lifecycle_dates(product):
    logger.debug(f"Getting lifecycle dates for product: {product}")
    if product == "sync-gateway":
        product = "sync_gateway"
        logger.debug("Converted sync-gateway to sync_gateway for file lookup")
    if product == "couchbase/server":
        product = "couchbase-server"
        logger.debug("Converted couchbase-server to couchbase/server for file lookup")
    json_path = f"repos/product-metadata/{product}/lifecycle_dates.json"
    logger.debug(f"Reading lifecycle dates from: {json_path}")
    try:
        with open(json_path) as f:
            dates = json.load(f)
            logger.debug(f"Successfully retrieved lifecycle dates for {product}")
            return dates
    except FileNotFoundError as e:
        logger.info(f"No lifecycle dates found for {product} at {json_path} ")
        return {}
