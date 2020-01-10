#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

if [[ "$VERSION" =~ "2.*" ]]
then
    TAG=$VERSION
    git clone git://github.com/couchbase/couchbase-java-client
    pushd couchbase-java-client
    if git rev-parse --verify --quiet $TAG >& /dev/null
    then
        echo "Tag $TAG exists, checking it out"
        git checkout $TAG
    else
        echo "No tag $TAG, assuming master"
    fi
    popd

    git clone git://github.com/couchbase/couchbase-jvm-core
    echo "WARNING: always using master branch of couchbase-jvm-core"
else
    TAG=java-client-$VERSION
    git clone git://github.com/couchbase/couchbase-jvm-clients
    pushd couchbase-jvm-clients
    if git rev-parse --verify --quiet $TAG >& /dev/null
    then
        echo "Tag $TAG exists, checking it out"
        git checkout $TAG
    else
        echo "No tag $TAG, assuming master"
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
fi
