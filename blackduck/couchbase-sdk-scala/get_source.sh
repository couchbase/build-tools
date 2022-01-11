#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com/couchbase/couchbase-jvm-clients
pushd couchbase-jvm-clients
TAG="scala-client-${VERSION}"
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "$TAG exists, checking it out"
    git checkout $TAG
else
    echo "No $TAG tag or branch, assuming master"
fi

# And now we actually need to build stuff for it to be found
# by the detector
mvn --batch-mode dependency:resolve || {
    for project in core-io-deps test-utils . ; do
        pushd $project
        mvn --batch-mode -Dmaven.test.skip=true install
        popd
    done
}

popd
