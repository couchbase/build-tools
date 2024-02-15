#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com/couchbase/gocb.git
pushd gocb
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

popd
