#!/bin/bash -e

# Searches for versions of couchbase-server and sync-gateway on RHCC
# newer than a specified cutoff version, and produces .properties files
# suitable for invoking the update-rhcc job.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

PYSCRIPT=$(cat <<EOF
import re
import sys
import json

regex = re.compile('^\d+\.\d+\.\d+$')
tags = json.load(sys.stdin)["tags"]
print (' '.join([t for t in tags if regex.match(t)]))
EOF
)

function do_product {
    local product=$1
    local min_ver=$2

    local versions=$("${SCRIPT_DIR}/get-tag-list.sh" ${product} | python -c "$PYSCRIPT")

    for version in ${versions}; do
        version_lt ${version} ${min_ver} && continue
        echo "Triggering rebuild of ${product} ${version}"
        cat > ${product}-${version}-republish.properties <<EOF
PRODUCT=${product}
VERSION=${version}
EOF
    done
}

# Don't rebuild versions older than these specified - currently these cutoffs
# are chosen because they are the earliest versions with multiple arches, and
# update-rhcc will always try to publish both arm64 and amd64
do_product couchbase-server 7.1.3
do_product sync-gateway 3.0.4
