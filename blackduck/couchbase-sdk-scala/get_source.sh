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

# The fit-performer packages are test-only and require a non-public
# jar, so they'll never be shipped; but their poms mess up the scans.
rm -rf *-fit-performer

# And now we actually need to build stuff for it to be found
# by the detector
mvn --batch-mode dependency:resolve || {
    for project in protostellar core-io-deps test-utils tracing-opentelemetry-deps . ; do
        if [ -e "$project" ]; then
            mvn --batch-mode -f "$project/pom.xml" -Dmaven.test.skip=true clean install
        fi
    done
}

popd
