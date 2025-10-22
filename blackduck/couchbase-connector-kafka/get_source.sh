#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

MAVEN_VERSION=3.9.6

cbdep install -d "${WORKSPACE}/extra" mvn ${MAVEN_VERSION}
export PATH="${WORKSPACE}/extra/mvn-${MAVEN_VERSION}/bin:${PATH}"

git clone ssh://git@github.com/couchbase/kafka-connect-couchbase.git
pushd kafka-connect-couchbase
if git rev-parse --verify --quiet $VERSION >& /dev/null
then
    echo "Tag $VERSION exists, checking it out"
    git checkout $VERSION
else
    echo "No tag $VERSION, assuming master"
fi

# don't need to scan examples
rm -rf examples

# Tell BD's custom settings.xml to skip the Couchbase maven cache for snapshots
export M2_MIRROROF="external:*,!central-portal-snapshots"

mvn --batch-mode -Dmaven.repo.local=/home/couchbase/.m2/${PRODUCT}-repository dependency:resolve
mvn --batch-mode -Dmaven.repo.local=/home/couchbase/.m2/${PRODUCT}-repository -Dmaven.test.skip=true -Dmaven.javadoc.skip=true install

popd
