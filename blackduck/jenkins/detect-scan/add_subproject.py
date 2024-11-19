#!/usr/bin/env python3

import argparse
import json
import logging
import pprint
import sys
from pathlib import Path

from blackduck import Client

# logging
logger = logging.getLogger()
handler = logging.StreamHandler()
formatter = logging.Formatter('%(levelname)-8s %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)
logger.setLevel('INFO')

parser = argparse.ArgumentParser('Add a sub-project to a project')
parser.add_argument('parent_project')
parser.add_argument('version')
parser.add_argument('sub_project_json')
args = parser.parse_args()


creds_file = str(Path.home()) + '/.ssh/blackduck-creds.json'
if Path(creds_file).exists():
    bd_creds =json.loads(open(creds_file).read())
else:
    sys.exit('Unable to locate blackduck-creds.json')

if Path(args.sub_project_json).exists():
    sub_project_list = json.loads(open(args.sub_project_json).read())['sub-projects']
    logger.info('Loading ' + args.sub_project_json)
else:
    sys.exit('Unable to locate ' + args.sub_project_json)
client = Client(base_url=bd_creds["url"], token=bd_creds["token"])

parent_project_version = None
try:
    parent_project = next(client.get_resource('projects', params={"q": f"name:{args.parent_project}"}))
except StopIteration:
    sys.exit(f"Project {args.parent_project} not found!")
try:
    parent_project_version = next(client.get_resource('versions', parent_project, params={"q": f"versionName:{args.version}"}))
except StopIteration:
    sys.exit(f"Version {args.version} for project {args.parent_project} not found!")

#create parent/sub project relationships
for sub_project_name in sub_project_list:
    try:
        sub_project = next(client.get_resource('projects', params={"q": f"name:{sub_project_name}"}))
    except StopIteration:
        sys.exit(f"Sub-project {sub_project_name} not found!")

    #Get all version of the sub-project from blackduck
    #Find the latest of x.y.z and add it as the sub-project
    #For example:
    #  couchbase-lite-core has 2.7.4, 2.8.0, 2.8.4, 3.0.0
    #    2.7.x is mercury
    #    2.8.x is hydrogen
    #    3.0.x is lithium
    #  when adding it as sub-project for CBL android 2.8.5, the version to match is 2.8.
    #  and 2.8.4 should be picked.
    version_to_match=args.version.rsplit('.', 1)[0]
    sub_project_versions = [
        v for v in client.get_resource('versions', sub_project)
        if v['versionName'].startswith(version_to_match)
    ]
    sub_project_versions = sorted(
        sub_project_versions, key=lambda k: k['versionName'],
        reverse=True
    )
    if len(sub_project_versions) < 1:
        sys.exit(f"No version {version_to_match}.x is found on blackduck for {sub_project_name}")

    # Dig out the parent project-version's "components" URL
    parent_components = client.list_resources(parent_project_version)['components']

    # Convert the subproject-version to a "components" URL (yes, apparently
    # you can kinda just do this)
    sub_project_component = \
        client.list_resources(sub_project_versions[0])['href'].replace(
            '/projects/', '/components/'
        )

    # POST this sub-project component to the parent's components
    payload = {
        "component": sub_project_component
    }
    headers = {
        'accept': "application/json",
        'content-type': "application/vnd.blackducksoftware.bill-of-materials-6+json"
    }
    response = client.session.post(parent_components, json=payload, headers=headers)
    response.raise_for_status()
    print(f"Added {sub_project_name} to {args.parent_project}")
