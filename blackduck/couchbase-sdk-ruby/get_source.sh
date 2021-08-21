#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

TAG=$VERSION
git clone git://github.com/couchbase/couchbase-ruby-client.git
pushd couchbase-ruby-client
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi
git submodule update --init --recursive
find . -type d -name \*test\* -print0 | xargs -0 rm -rf
popd
