#!/usr/bin/python

import base64
import sys
import json
import os
import argparse
from urllib.request import Request, urlopen

parser = argparse.ArgumentParser()
parser.add_argument("jenkins", type=str, help="Jenkins to connect to",
    nargs='?', default="server.jenkins.couchbase.com")
parser.add_argument("--job", type=str, help="Mount local directories",
    nargs="+")
args = parser.parse_args()

jenkins = args.jenkins
jobs = args.job

if not os.environ.get('jenkins_user') or not os.environ.get('jenkins_token'):
    print("Authentication required for '{0}'".format(jenkins))
    print("Ensure jenkins_user and jenkins_token environment variables are populated")
    exit(1)

joburl = 'http://{0}/job/{1}/api/json'
warning = False
for job in jobs:
    request = Request(joburl.format(jenkins, job))
    auth_arg = '%s:%s' % (os.environ.get('jenkins_user'), os.environ.get('jenkins_token'))
    base64string = base64.b64encode(auth_arg.encode())
    request.add_header("Authorization", "Basic %s" % base64string.decode())
    response = urlopen(request)

    jobdata = json.load(response)

    if (jobdata['disabled']):
        print(f"\n\n\n*************\nWarning: Job '{job}' is currently disabled\n**************")
        warning = True

if warning:
    sys.exit(1)
