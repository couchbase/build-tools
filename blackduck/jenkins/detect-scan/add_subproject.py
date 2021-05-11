#!/usr/bin/env python3

import argparse
import json
import logging
import sys, os
from pathlib import Path

from blackduck.HubRestApi import HubInstance, object_id

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
    sys.exit('Unable to locate ' + sub_project_json)
hub = HubInstance(bd_creds['url'], bd_creds['username'], bd_creds['password'], insecure=True)

parent_project = hub.get_project_version_by_name(args.parent_project, args.version)
if parent_project is None:
    #unable to add sub-project when project or its version doesn't exist
    sys.exit(parent_project+' or its version is NOT found.')

#create parent/sub project relationships
for sub_project_name in sub_project_list:
    sub_project = hub.get_project_by_name(sub_project_name)
    if sub_project is None:
        sys.exit(sub-project +' does not exist on blackduck. It can NOT be added as a sub-project.')
    sub_project_versions = hub.get_project_versions(sub_project)
    if 'totalCount' in sub_project_versions and sub_project_versions['totalCount'] > 0:
        #Get all version of the sub-project from blackduck
        #Find the latest of x.y.z and add it as the sub-project
        #For example:
        #  couchbase-lite-core has 2.7.4, 2.8.0, 2.8.4, 3.0.0
        #    2.7.x is mercury
        #    2.8.x is hydrogen
        #    3.0.x is lithium
        #  when adding it as sub-project for CBL android 2.8.5, the version to match is 2.8.
        #  and 2.8.4 should be picked.
        versions = sub_project_versions['items']
        sorted_versions = sorted(versions, key=lambda k: k['versionName'], reverse=True)
        version_to_match=args.version.rsplit('.', 1)[0]
        index = next((index for (index, d) in enumerate(sorted_versions) if version_to_match in d['versionName']), None)
        if index is None:
            sys.exit("No matching version is found for sub-project: " + sub_project_name)
        hub.add_version_as_component(parent_project, sorted_versions[index])
    else:
        sys.exit('No version is found on blackduck for ' + sub_project_name)
