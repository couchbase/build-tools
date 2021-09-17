#!/usr/bin/python

import base64
import sys
import json
import os
import argparse
import socket
from urllib.error import URLError
from urllib.request import Request, urlopen

parser = argparse.ArgumentParser()
parser.add_argument("jenkins", type=str, help="Jenkins to connect to",
    nargs='?', default="server.jenkins.couchbase.com")
parser.add_argument("--job", type=str, help="Job name(s)",
    nargs="+", required=True)
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
    try:
        response = urlopen(request, timeout=20)
    except URLError as e:
        # We get occasional timeouts, which we'd rather not hear about
        # since this script will run again in 15 minutes anyway. By setting
        # timeout=20 above, urllib will abort with a socket.timeout after
        # 20 seconds, so catch that here.
        if isinstance(e.reason, socket.timeout):
            print("Got a timeout; ignoring")
            continue
        else:
            raise

    jobdata = json.load(response)

    if (jobdata['disabled']):
        print(f"\n\n\n*************\nWarning: Job '{job}' is currently disabled\n**************")
        warning = True

if warning:
    sys.exit(1)
