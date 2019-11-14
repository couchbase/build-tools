#!/usr/bin/env python3

import argparse
import json
import logging
import os
import sys
import time
import zipfile

from blackduck.HubRestApi import HubInstance
from pathlib import Path

logger = logging.getLogger('blackduck/download-reports')
logger.setLevel(logging.DEBUG)
logging.getLogger("requests").setLevel(logging.WARNING)
logging.getLogger("urllib3").setLevel(logging.WARNING)
ch = logging.StreamHandler()
logger.addHandler(ch)

class FailedDownload(Exception):
    pass

class ReportsDownloader:
    def __init__(self, product, version, bld_num, cred_file, output_dir):
        """
        Connects to Hub and initializes Project and Version
        """

        self.product_name = product
        self.version_name = version
        self.prefix = f"{product}-{version}-{bld_num}"
        self.output_dir = Path(output_dir).resolve()
        self.tmp_zip = self.output_dir / "tmp.zip"

        # Connect to Black Duck
        creds = json.load(cred_file)
        logger.info(f"Connecting to Black Duck hub {creds['url']}")
        self.hub = HubInstance(creds["url"], creds["username"], creds["password"], insecure=True)

        self.product = self.hub.get_project_by_name(product)
        if not self.product:
            raise Exception(f"Unknown product {product}")
        self.version = self.hub.get_version_by_name(self.product, version)
        if not self.version:
            raise Exception(f"Unknown version {version} for product {product}")

    def download_report(self, report_name, location):
        """
        Waits for a specified report to be available, then downloads all
        contents to the specified directory
        """

        report_id = location.split("/")[-1]
        logger.info(f"Downloading {report_name}")
        logger.debug(f"Report ID is {report_id}")
        retries = 100
        while retries > 0:
            response = self.hub.download_report(report_id)
            if response.status_code != 200:
                logger.debug(f"Report not ready yet, retrying #{retries}")
                time.sleep(6)
                retries -= 1
                continue
            logger.debug(f"Writing {report_name} to {self.tmp_zip}")
            with self.tmp_zip.open("wb") as f:
                f.write(response.content)
                self.unpack_report(report_name)
                return

        raise Exception(f"Failed to retrieve {report_name} {report_id} after many retries!")

    def unpack_report(self, report_name):
        """
        Unpacks the temp downloaded .zip from Hub, stripping the report
        identifier from the filename
        """

        # All entries in Hub reports are in a directory (whose name we don't
        # care about), and have a filename like "goodpart_YYYY-MM-DD_RANDOM.ext".
        # Break this apart and rename to "PRODUCT-VERSION-BLD_NUM-goodpart.ext"
        logger.info(f"Extracting {report_name}")
        with zipfile.ZipFile(self.tmp_zip) as z:
            for entry in z.infolist():
                if entry.is_dir():
                    continue
                in_file = Path(entry.filename)
                goodpart = in_file.name.split("_")[0]
                # Special case for "notices" file
                if goodpart == "version-license":
                    goodpart = "notices"
                ext = in_file.suffix
                out_file = self.output_dir / f"{self.prefix}-{goodpart}{ext}"
                logger.debug(f"Writing {out_file}")
                with out_file.open("wb") as out:
                    with z.open(entry) as content:
                        out.write(content.read())

        self.tmp_zip.unlink()

    def start_reports(self):
        """
        Requests creation of all CSV reports for product-version
        """

        logger.info(f"Requesting creation of CSV reports")
        response = self.hub.create_version_reports(
            self.version,
            ['VERSION', 'CODE_LOCATIONS', 'COMPONENTS', 'SECURITY', 'FILES'],
            'CSV'
        )
        if response.status_code != 201:
            logger.debug(response.content)
            raise Exception(f"Error {response.status_code} creating CSV reports")
        self.reports_location = response.headers['Location']

    def start_notices(self):
        """
        Requests creation of Notices file for product-version
        """

        logger.info(f"Requesting creation of Notices file")
        response = self.hub.create_version_notices_report(self.version, 'TEXT')
        if response.status_code != 201:
            logger.debug(response.content)
            raise Exception(f"Error {response.status_code} creating Notices file")
        self.notices_location = response.headers['Location']
        logger.debug(f"Notices location is {self.notices_location}")

    def download_scans(self):
        """
        Downloads all scan .bdio files for product-version, and collects them
        into a .zip
        """

        logger.info(f"Downloading .bdio scans")
        output = self.hub.download_project_scans(
            self.product_name, self.version_name,
            str(self.output_dir)
        )

        logger.debug(f"Creating {self.prefix}-bdio.zip")
        with zipfile.ZipFile(self.output_dir / f"{self.prefix}-bdio.zip", "w") as z:
            for entry in output:
                # I think the API *meant* to use a tuple here, but instead
                # they used a two-item set, so we have to guess which one is
                # the filename
                for filename in entry:
                    path = Path(filename)
                    if not path.is_absolute():
                        continue
                    logger.debug(f"Adding {path} to zip")
                    z.write(path, arcname=path.name)
                    path.unlink()

        logger.info(f"Downloaded {len(output)} scans")

    def download(self):
        """
        Invokes each of the download steps in turn, and waits for completion
        """

        self.start_reports()
        self.start_notices()

        self.download_scans()
        self.download_report("CSV reports", self.reports_location)
        self.download_report("Notices file", self.notices_location)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description='Download collection of reports from Black Duck Hub'
    )
    parser.add_argument('product', help='Product from Black Duck server')
    parser.add_argument('version', help='Version of <product>')
    parser.add_argument('bld_num', help='Build number of <product> (for output file naming)')
    parser.add_argument('-c', '--credentials', required=True,
                        type=argparse.FileType('r', encoding='UTF-8'),
                        help='Path to Black Duck server credentials JSON file')
    parser.add_argument('--output-dir', required=True,
                        help='Output path to directory for scans and reports')

    args = parser.parse_args()

    if not os.path.isdir(args.output_dir):
        logger.error(f"Output report directory does not exist: {args.output_dir}")
        sys.exit(1)

    downloader = ReportsDownloader(
        args.product, args.version, args.bld_num,
        args.credentials,
        args.output_dir
    )
    downloader.download()
