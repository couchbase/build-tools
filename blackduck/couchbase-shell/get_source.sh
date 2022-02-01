#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

GIT_TAG="v${VERSION}"

git clone ssh://git@github.com/couchbaselabs/couchbase-shell.git
pushd couchbase-shell
if git rev-parse --verify --quiet ${GIT_TAG} >& /dev/null
then
    echo "Tag ${GIT_TAG} exists, checking it out"
    git checkout ${GIT_TAG}
else
    echo "No tag ${GIT_TAG}, assuming main"
fi
