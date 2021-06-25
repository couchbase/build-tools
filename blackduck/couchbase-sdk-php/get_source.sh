#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone git://github.com/couchbase/php-couchbase.git
pushd php-couchbase
TAG="v$VERSION"
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi

# Work-around for Black Duck Detect bug
sed -i '/DOCTYPE/d' package.xml

popd
