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
for p in sub_project_list:
    sub_project = hub.get_project_version_by_name(p, args.version)
    if sub_project is None:
        sys.exit(sub-project+' or its version does not exist. It can NOT be added as a sub-project.')
    else:
        hub.add_version_as_component(parent_project, sub_project)
