#!/bin/bash -e

# Reaches out to the RHCC REST API and returns a JSON object describing
# the available tags for the specified image name (couchbase/server, etc).
# Result looks like this:
#
#  {"name":"couchbase/server","tags":["5.5.1-1","6.0.1-1","6.0.3-1", ...}
#
# Note that our "added" tags such as :6.5.0 and :latest WILL be included,
# in addition to the ones we initially pushed such as :6.5.0-1.

PRODUCT=$1
shift

# Do OAuth dance with RHCC
tokenUri="https://sso.redhat.com/auth/realms/rhcc/protocol/redhat-docker-v2/auth?service=docker-registry&client_id=curl&scope=repository:rhel:pull"
# This is a "Registry Service Account" on access.redhat.com associated with the rhel8-couchbase user
set +x
username=$(cat ${HOME}/.docker/rhcc-metadata.json | jq -r .rhcc.registry_service_account.username)
password=$(cat ${HOME}/.docker/rhcc-metadata.json | jq -r .rhcc.registry_service_account.password)
image_name=couchbase/$(cat ${HOME}/.docker/rhcc-metadata.json | jq -r '.products."'${PRODUCT}'".image_basename')

# Obtain short-duration access token from auth server
token=$(curl --fail --silent -L --user "$username:$password" --get $tokenUri |
        python -c 'import sys, json; print (json.load(sys.stdin)["token"])')

listUri="https://registry.connect.redhat.com/v2/${image_name}/tags/list"
curl --fail --silent -H "Accept: application/json" -H "Authorization: Bearer $token" --get -H "Accept: application/json" $listUri
