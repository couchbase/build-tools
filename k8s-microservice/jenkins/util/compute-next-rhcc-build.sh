#!/bin/bash -ex

# Basic help information
function show_help {
    echo "Usage: $0 <options>"
    echo "Options:"
    echo "  -p : Product to publish (e.g. couchbase-operator)"
    echo "  -v : Version to republish (eg. 2.0.2) (Required)"
    exit 0
}

# Parse options and ensure required ones are there
while getopts :p:v:b:h opt; do
    case ${opt} in
        p) PRODUCT="$OPTARG"
           ;;
        v) VERSION="$OPTARG"
           ;;
        h) show_help
           ;;
        \?) # Unrecognized option, show help
            echo -e \\n"Invalid option: ${OPTARG}" 1>&2
            show_help
    esac
done

if [[ -z "$PRODUCT" ]]; then
    echo "Product name (-p) is required"
    exit 1
fi

if [[ -z "$VERSION" ]]; then
    echo "Full version (-v) is required"
    exit 1
fi

# Do OAuth dance with RHCC
tokenUri="https://registry.connect.redhat.com/auth/realms/rhc4tp/protocol/redhat-docker-v2/auth"
# This is a "Registry Service Account" on access.redhat.com associated with the rhel8-couchbase user
username='7638313|rhel8-couchbase'
set +x
password=$(cat /home/couchbase/openshift/rhcc/registry-service-token.txt)
# Obtain short-duration access token from auth server
data=("service=docker-registry" "client_id=curl" "scope=repository:rhel:pull")
token=$(curl --fail --silent -L --user "$username:$password" --get --data-urlencode ${data[0]} --data-urlencode ${data[1]} --data-urlencode ${data[2]} $tokenUri |
        python -c 'import sys, json; print(json.load(sys.stdin)["token"])')

# Ask RHCC for tag numbers and pick out the last one
PYSCRIPT=$(cat <<EOF
import sys
import json

tags = json.load(sys.stdin)["tags"]
highest = 0
for tag in tags:
    if tag.startswith("${VERSION}-"):
        bldno = int(tag.split('-')[-1])
        if bldno > highest:
            highest = bldno
print(highest + 1)
EOF
)

SHORT_PRODUCT=${PRODUCT/couchbase-/}
listUri="https://registry.connect.redhat.com/v2/couchbase/${SHORT_PRODUCT}/tags/list"
nextbld="$(curl --fail --silent -H "Authorization: Bearer $token" --get -H "Accept: application/json" $listUri | python -c "$PYSCRIPT")"
echo "Next build number for $VERSION is $nextbld"
echo "NEXT_BLD=$nextbld" > nextbuild.properties
