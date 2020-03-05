#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone git://github.com/couchbase/couchbase-jvm-clients
pushd couchbase-jvm-clients
if git rev-parse --verify --quiet $RELEASE >& /dev/null
then
    echo "$RELEASE exists, checking it out"
    git checkout $RELEASE
else
    echo "No $RELEASE tag or branch, assuming master"
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
