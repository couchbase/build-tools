#!/bin/bash -ex

SCRIPT_ROOT="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# example usage
# get_source.sh couchbase-sdk-ruby 3.4.5 3.4.5 9999

# "couchbase-sdk-ruby", ignored in this script
PRODUCT=$1
# by default this will be the same as VERSION; however, if your scan-config.json specified a release key for this version, that value will be passed here
RELEASE=$2
# one of the version keys from scan-config.json
VERSION=$3
# ignored in this script, as it is not useful for SDK scans (will be 9999)
BLD_NUM=$4

exec ruby ${SCRIPT_ROOT}/get_source.rb $VERSION $RELEASE
