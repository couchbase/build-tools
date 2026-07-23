#!/bin/bash -ex

# ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your
# scan-config.json specified a release key for this version, that value
# will be passed here
RELEASE=$2
# One of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

git clone git@github.com:couchbase/lighthouse.git
pushd lighthouse
TAG="v$VERSION"
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi

# Add golang version from go.mod to ${WORKSPACE}/extra
export PATH="$(${WORKSPACE}/build-tools/blackduck/jenkins/util/go-path-from-mod.sh):$PATH"

go mod vendor

popd
