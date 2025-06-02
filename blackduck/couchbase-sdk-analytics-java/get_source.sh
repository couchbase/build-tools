#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

MAVEN_VERSION=3.6.3

cbdep install -d "${WORKSPACE}/extra" mvn ${MAVEN_VERSION}
export PATH="${WORKSPACE}/extra/mvn-${MAVEN_VERSION}/bin:${PATH}"

TAG=$VERSION
git clone ssh://git@github.com/couchbaselabs/couchbase-analytics-jvm-clients
pushd couchbase-analytics-jvm-clients
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi

# The fit-performer packages are test-only and require a non-public
# jar, so they'll never be shipped; but their poms mess up the scans.
rm -rf couchbase-analytics-java-client/fit
rm -rf couchbase-analytics-java-client/examples

popd
