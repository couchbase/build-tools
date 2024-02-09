#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

OPENJDK_VERSION=8u292-b10

cbdep install -d "${WORKSPACE}/extra" openjdk-jre ${OPENJDK_VERSION}
export JAVA_HOME="${WORKSPACE}/extra/openjdk-jre-${OPENJDK_VERSION}"
export PATH="${JAVA_HOME}/bin:$PATH"

git clone ssh://git@github.com/couchbase/couchbase-spark-connector.git

pushd couchbase-spark-connector
if git rev-parse --verify --quiet $VERSION >& /dev/null
then
    echo "Tag $VERSION exists, checking it out"
    git checkout $VERSION
else
    echo "No tag $VERSION, assuming master"
fi

# don't need to scan examples or docs
rm -rf src/test
rm -rf docs

# Install sbt
SBT_VERSION=$(cat project/build.properties |grep "sbt.version" |awk -F '=' '{print $2}' |tr -d '[:space:]')
wget https://github.com/sbt/sbt/releases/download/v${SBT_VERSION}/sbt-${SBT_VERSION}.tgz -O - |tar -xz -C ../../extra

# Add dependency graph plugin required by blackduck
echo '' >> project/plugins.sbt
echo 'addSbtPlugin("net.virtual-void" % "sbt-dependency-graph" % "0.10.0-RC1")' >> project/plugins.sbt

# Blackduck doesn't support buildless scan of scala project as of 7.0.0
# Hence, we need to build it before passing the project through the scanner.
../../extra/sbt/bin/sbt clean compile

popd
