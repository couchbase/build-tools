#!/usr/bin/env python3

import argparse
import logging
import pathlib
import sys
import yaml

from typing import Optional

class GoManifestBuilder:

    def __init__(self, go_versions: pathlib.Path, output: pathlib.Path) -> None:
        """
        Get ready
        """

        with go_versions.open() as m:
            self.go_versions = yaml.safe_load(m)
        self.output: pathlib.Path = output
        self.max_ver_file: Optional[pathlib.Path] = None
        self.debug: bool = False


    def set_debug(self, debug: bool) -> None:
        """
        Enable debug logging
        """

        self.debug = debug


    def set_max_ver_file(self, max_ver_file: Optional[pathlib.Path]) -> None:
        """
        Specify the file to write the maximum Go version into
        """

        self.max_ver_file = max_ver_file


    def generate(self) -> None:
        """
        Create output report
        """

        versions = set()
        for gover in self.go_versions['go-versions']:
            # Each element in go-verions array is an object with a single key
            # that is the Go versions
            versions.update(gover.keys())

        max_ver = sorted(versions).pop()
        logging.debug(f"Highest Go version: {max_ver}")

        logging.info(f"Generating {self.output}")
        mani = {
            "components": {
                "go programming language": {
                    "bd-id": "6d055c2b-f7d7-45ab-a6b3-021617efd61b",
                    "versions": sorted(versions)
                }
            }
        }
        with self.output.open('w') as f:
            yaml.dump(mani, f)

        if self.max_ver_file is not None:
            logging.info(f"Writing '{max_ver}' to {self.max_ver_file}")
            self.max_ver_file.write_text(max_ver)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Go Manifest Builder"
    )
    parser.add_argument(
        '-g', '--go-versions', type=pathlib.Path, required=True,
        help="Path to go-versions file"
    )
    parser.add_argument(
        '-o', '--output', type=pathlib.Path,
        default="couchbase-server-black-duck-manifest.yaml",
        help="Output manifest to generate"
    )
    parser.add_argument(
        '-m', '--max-ver-file', type=pathlib.Path,
        help="File to write max Go versions into"
    )
    parser.add_argument(
        '-d', '--debug', action="store_true",
        help="Enable debug output"
    )

    args = parser.parse_args()

    # Initialize logging
    logging.basicConfig(
        stream=sys.stderr,
        format='%(asctime)s: %(levelname)s: %(message)s',
        level=logging.DEBUG if args.debug else logging.INFO
    )

    builder = GoManifestBuilder(args.go_versions, args.output)
    builder.set_debug(args.debug)
    builder.set_max_ver_file(args.max_ver_file)
    builder.generate()
