import argparse
import json
import logging
import os
import sys
import yaml

def load_shipped_repodirs(yaml_file):
    """
    Loads all directories from the go-versions.yaml file that are not
    marked as unshipped. Returns a set of directories, with trailing /
    character.
    """
    with open(yaml_file, 'r') as f:
        data = yaml.safe_load(f)

    repodirs = set()
    # Each element in go-verions array is an object with a single key
    # that is the Go version
    for gover in data.get("go-versions"):
        for _, targets in gover.items():
            for target in targets:
                name = target.get("target")
                if target.get("unshipped", False):
                    # If target isn't shipped, skip it
                    logging.debug(f"Skipping unshipped target: {name}")
                    continue
                logging.debug(f"Adding shipped target: {name}")
                repodirs.add(target["repodir"] + "/")

    return repodirs

def find_unshipped_gomod(root_dir, shipped_repodirs):
    """
    Walks the directory tree starting from root_dir and finds all
    directories containing a go.mod file. Returns a list of directories
    that are not in shipped_repodirs, so they can be excluded from the
    Black Duck scan.
    """
    unmatched = []

    for dirpath, _, filenames in os.walk(root_dir):
        if 'go.mod' in filenames:
            # Get the relative path from the root directory
            rel_path = os.path.relpath(dirpath, root_dir) + "/"

            # Check if any shipping targets are in this directory or any
            # subdirectory - ie, if this directory is a leading portion
            # of any shipping target
            if not any(
                shipped_dir.startswith(rel_path)
                for shipped_dir in shipped_repodirs
            ):
                logging.debug(f"Excluding go.mod directory: {rel_path}")
                unmatched.append(rel_path)

    logging.info(f"Excluded {len(unmatched)} directories from scan")
    return unmatched

if __name__ == "__main__":

    parser = argparse.ArgumentParser(description="Find go.mod repos")
    parser.add_argument("--go-versions", "-g", required=True,
                        help="Path to go-versions.yaml")
    parser.add_argument("--root", "-r", required=True,
                        help="Root directory to scan for go.mod files")
    parser.add_argument("--output", "-o", required=True,
                        help="Output detect-config.json file")
    parser.add_argument("--extra-excludes", "-x", action="append", default=[],
                        help="Extra excludes to add to detect-config.json")
    parser.add_argument("--debug", "-d", action="store_true",
                        help="Enable debug output")

    args = parser.parse_args()

    # Initialize logging
    logging.basicConfig(
        stream=sys.stderr,
        format='%(asctime)s: %(levelname)s: %(message)s',
        level=logging.DEBUG if args.debug else logging.INFO
    )

    shipped_repodirs = load_shipped_repodirs(args.go_versions)
    unmatched = find_unshipped_gomod(args.root, shipped_repodirs)
    unmatched.extend(args.extra_excludes)

    detect_config = {
        "detect_opts": {
            "detect.excluded.directories": ",".join(unmatched)
        }
    }

    # Write the detect-config.json file
    with open(args.output, 'w') as f:
        json.dump(detect_config, f, indent=2)
    logging.info(f"Generated JSON: {args.output}")