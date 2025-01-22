#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

MAVEN_VERSION=3.9.9

cbdep install -d "${WORKSPACE}/extra" mvn ${MAVEN_VERSION}
export PATH="${WORKSPACE}/extra/mvn-${MAVEN_VERSION}/bin:${PATH}"

git clone ssh://git@github.com/quarkiverse/quarkus-couchbase.git
pushd quarkus-couchbase
if git rev-parse --verify --quiet $VERSION >& /dev/null
then
    echo "Tag $VERSION exists, checking it out"
    git checkout $VERSION
else
    echo "No tag $VERSION, assuming main"
fi
popd
