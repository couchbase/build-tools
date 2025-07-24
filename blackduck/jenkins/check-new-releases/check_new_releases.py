#!/usr/bin/env -S uv run
# /// script
# requires-python = "==3.12.3"
# dependencies = ['GitPython==3.1.37', 'packaging==23.2']
# [tool.uv]
# exclude-newer = "2025-07-24T00:00:00Z"
# ///

import git
import json
import logging
import os
import re
import shutil
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILD_TOOLS_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
BLACKDUCK_DIR = os.path.abspath(os.path.join(BUILD_TOOLS_DIR, "blackduck"))
WORK_DIR = os.path.join(SCRIPT_DIR, "build")
BUILD_TOOLS_REPO = git.Repo(BUILD_TOOLS_DIR)

ignorelist = [
    # We only scan main for couchbase-cloud
    "couchbase-cloud",
]

# Typically we're just looking for branches which look like versions,
# but we need to account for repos which have prefixes on their tags.
# Note: keys are based on directory names, rather than repository names
tag_prefixes = {
    "couchbase-sdk-go": "v",
    "couchbase-sdk-java": "java-client-",
    "couchbase-sdk-kotlin": "kotlin-client-",
    "couchbase-sdk-nodejs": "v",
    "couchbase-sdk-ottoman": "v",
    "couchbase-sdk-scala": "scala-client-",
    "couchbase-shell": "v",
}


def delete_dir_if_exists(dir):
    """
    Remove a directory if it exists

    Parameters:
    dir (str): The directory to be removed
    """
    if os.path.exists(dir) and os.path.isdir(dir):
        logging.debug(f"Deleting {dir}")
        shutil.rmtree(dir)
    else:
        logging.debug(f"{dir} does not exist, not deleting")


def get_repo_from_script(script):
    """
    Get the first mentioned GitHub org/repo combination from a script

    Parameters:
    script (str): Path to the script to be searched

    Returns:
    str: First org/repo mentioned in script
    """
    git_url_pattern = re.compile(r'github\.com[/:]([^/]+)/([^/\.\n ]+)')

    with open(script, 'r') as file:
        for line in file:
            match = git_url_pattern.search(line)
            if match:
                org, repo = match.groups()
                return f"{org}/{repo}"


def clone_repo(repo):
    """
    Clone a repository, deleting the local directory first if it exists

    Parameters:
    repo (str): Repository being cloned

    Returns:
    git.repo.base.Repo: Resulting repo object for cloned repo
    """
    delete_dir_if_exists(os.path.join(WORK_DIR, repo.split("/")[-1]))
    logging.debug(f"Cloning {repo}")
    repo = git.Repo.clone_from(
        f"git@github.com:{repo}", os.path.join(WORK_DIR, repo.split("/")[-1]))
    return repo


def get_main_branch(repo):
    """
    Get the main branch of a repository

    Parameters:
    repo (git.repo.base.Repo): Repository being checked

    Returns:
    str: The name of the main branch
    """
    return repo.head.reference.name

def get_tags(repo):
    """
    Get a list of tags from a github repository

    Parameters:
    repo (str): Repository being checked

    Returns:
    dict: dict of tags, with commit + timestamp for each
    """
    tags = {}
    for tag in repo.tags:
        tags[tag.name] = {
            'commit': tag.commit.hexsha,
            'timestamp': tag.commit.committed_date,
        }
    return tags


def load_json_file(json_file):
    """
    Get the contents of a json document

    Parameters:
    json_file (str): The document to be loaded

    Returns:
    dict: The contents of the file
    """
    with open(json_file, 'r') as file:
        data = json.load(file)
    logging.debug(f"Json loaded: {json_file}")
    return data


def sort_dict(d, reverse=True):
    """
    Sort a dict by key alphanumerically - e.g: a1 < a2 < a10

    Parameters:
    d (dict): Unsorted dict

    Returns:
    dict: Sorted dict
    """
    def sort_key(version_string):
        segments = re.split(r'(\d+)', version_string)
        return [int(segment) if segment.isdigit() else segment for segment in segments]

    return dict(sorted(d.items(), key=lambda x: sort_key(x[0]), reverse=reverse))


def has_master_release(versions, main_branch):
    """
    Check if any version already has a release field pointing to master/main

    Parameters:
    versions (dict): versions dict from scan_config
    main_branch (str): name of the main branch (master or main)

    Returns:
    bool: True if a version with release=master/main already exists
    """
    for version_config in versions.values():
        if isinstance(version_config, dict) and version_config.get('release') == main_branch:
            return True
    return False


def get_latest_timestamp(versions, tags):
    """
    Get the most current version's timestamp

    Parameters:
    versions (dict): versions dict from scan_config
    tags (dict): tags dict from get_tags

    Returns:
    str: timestamp
    """
    try:
        latest_version = list(sort_dict(versions).items())[0][0]
    except IndexError:
        # If there are no versions in scan-config.json, return zero timestamp
        # as we'll need to check all tags
        return 0
    if latest_version in tags:
        return tags[latest_version]['timestamp']
    else:
        # If the most recent tag in scan-config.json isn't in the repo
        # tags, it'll be master/main so we don't need to consider
        # anything newer
        return time.time()


def update_scan_config(product_dir):
    """
    Ensure a given scan-config.json is up to date with all monitored tags
    from its repo

    Parameters:
    product_dir (str): The directory the scan-config.json lives in
    """
    scan_config_path = os.path.join(
        BLACKDUCK_DIR, product_dir, "scan-config.json")
    get_source_path = os.path.join(
        BLACKDUCK_DIR, product_dir, "get_source.sh")

    if os.path.isfile(scan_config_path) and os.path.isfile(get_source_path):
        logging.info(f"Checking {product_dir}")

        scan_config = load_json_file(scan_config_path)
        repo_name = get_repo_from_script(get_source_path)
        repo = clone_repo(repo_name)
        repo_tags = get_tags(repo)
        main_branch = get_main_branch(repo)
        latest_timestamp = get_latest_timestamp(
            scan_config['versions'], repo_tags)

        repo_tags[main_branch] = {
            'commit': repo.head.commit.hexsha,
            'timestamp': repo.head.commit.committed_date,
            'main': True,
        }

        tag_prefix = tag_prefixes.get(product_dir, "")

        # We walk through repo tags in chronological order since we're
        # comparing them to existing tags, and removing  previous version
        # with the same major.minor as the one we're adding
        for tag in sort_dict(repo_tags, reverse=False):
            # We're only interested in main, master, and tags which begin
            # with a version string (prefixed by the tag prefix for that
            # project if applicable)
            if not re.match(rf'^(main|master|{tag_prefix}\d+(\.\d+)*)$', tag):
                continue
            else:
                if tag == main_branch:
                    stripped_tag = tag
                else:
                    stripped_tag = tag[len(tag_prefix):]

            if stripped_tag not in scan_config['versions']:
                # For main branch, check if there's already a version with release=master/main
                if tag == main_branch and has_master_release(scan_config['versions'], main_branch):
                    logging.debug(f"* Skipping {stripped_tag} - already have version with release={main_branch}")
                    continue

                if repo_tags[tag]['timestamp'] >= latest_timestamp or tag == main_branch:

                    # Adding a newer version than the most recent in
                    # scan-config.json, so we need to remove any previous
                    # versions with the same major.minor if they are the
                    # same length or 1 char shorter (to account for versions
                    # such as 1.0.0-dp.9), and add an interval to the version
                    # we're adding
                    logging.info(f"* Adding {stripped_tag}")
                    superceded_versions = []
                    for k in scan_config['versions']:
                        if k.split('.')[:2] == stripped_tag.split('.')[:2] and (len(k) == len(stripped_tag) or len(k) == len(stripped_tag)-1):
                            logging.info(f"* Removing {k}")
                            superceded_versions.append(k)
                    for version in superceded_versions:
                        scan_config['versions'].pop(version)
                    scan_config['versions'][stripped_tag] = {"interval": 1440}
                else:
                    # Older versions than the most current in scan-config
                    # are ignored
                    continue

        scan_config['versions'] = sort_dict(scan_config['versions'])
        with open(scan_config_path, 'w') as file:
            file.write(json.dumps(
                scan_config, indent=4) + os.linesep)
        BUILD_TOOLS_REPO.git.add(scan_config_path)


def main():
    logging.basicConfig(level=logging.INFO,
                        format='%(asctime)s - %(levelname)s - %(message)s')
    logging.info("Checking for new releases...")
    for product_dir in os.listdir(BLACKDUCK_DIR):
        if product_dir in ignorelist:
            logging.debug(f"{product_dir} is on ignore list, skipping")
            continue
        else:
            logging.debug(f"Checking {product_dir}")
            update_scan_config(product_dir)


if __name__ == "__main__":
    main()
