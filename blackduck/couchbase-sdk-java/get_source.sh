#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

# current repo, do not remove:
# github.com/couchbase/couchbase-jvm-clients

if [[ "$VERSION" =~ "2.*" ]]
then
    TAG=$VERSION
    git clone ssh://git@github.com/couchbase/couchbase-java-client
    pushd couchbase-java-client
    if git rev-parse --verify --quiet $TAG >& /dev/null
    then
        echo "Tag $TAG exists, checking it out"
        git checkout $TAG
    else
        echo "No tag $TAG, assuming master"
    fi
    popd

    git clone ssh://git@github.com/couchbase/couchbase-jvm-core
    echo "WARNING: always using master branch of couchbase-jvm-core"
else
    TAG=java-client-$VERSION
    git clone ssh://git@github.com/couchbase/couchbase-jvm-clients
    pushd couchbase-jvm-clients
    if git rev-parse --verify --quiet $TAG >& /dev/null
    then
        echo "Tag $TAG exists, checking it out"
        git checkout $TAG
    else
        echo "No tag $TAG, assuming master"
    fi

    # The fit-performer packages are test-only and require a non-public
    # jar, so they'll never be shipped; but their poms mess up the scans.
    rm -rf *-fit-performer

    # And now we actually need to build stuff for it to be found
    # by the detector
    mvn --batch-mode dependency:resolve || {
        for project in protostellar core-io-deps test-utils . ; do
            if [ -e "$project" ]; then
                mvn --batch-mode -f "$project/pom.xml" -Dmaven.test.skip=true clean install
            fi
        done
    }

    popd
fi
