#!/bin/bash -ex

RELEASE=$1
MANIFEST=$2
VERSION=$3

BUILD_TOOLS=$(pwd)/build-tools

# First, download the scan tool
curl -L --insecure \
  https://mega3.build.couchbase.com/download/scan.cli.zip \
  -o scan.cli.zip

unzip scan.cli.zip
rm scan.cli.zip
export PATH=$(pwd)/$(echo scan.cli-*)/bin:$PATH

# Now create the source to scan
mkdir scansrc
cd scansrc
${BUILD_TOOLS}/blackduck/get_${RELEASE}.sh ${MANIFEST}

set +x
export BD_HUB_PASSWORD=$(cat ~/.ssh/blackduck-password.txt)
set -x

scan.cli.sh --username sysadmin \
  --scheme https --host mega3.build.couchbase.com --port 443 --insecure \
  --name "couchbase-server-blackduck-scan" \
  --project "Couchbase Server" --release ${VERSION} \
  $(pwd)
