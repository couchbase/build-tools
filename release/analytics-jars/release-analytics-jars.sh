#!/bin/bash -ex

RELEASE=$1
VERSION=$2
BLD_NUM=$3

# Download named build (use Ubuntu 18 - will need to update in far future
# when we no longer support Ubuntu 18)
curl -L http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/couchbase-server-enterprise_${VERSION}-${BLD_NUM}-ubuntu18.04_amd64.deb -o couchbase-server.deb

# Extract jar contents
ar x couchbase-server.deb
tar xf data.tar.xz --wildcards --no-wildcards-match-slash --strip-components 5 './opt/couchbase/lib/cbas/repo/*.jar'
pushd repo
tar cvzf ../analytics-jars-${VERSION}-${BLD_NUM}.tar.gz *.jar
popd

# Publish to S3
aws s3 cp analytics-jars-${VERSION}-${BLD_NUM}.tar.gz \
  s3://packages.couchbase.com/releases/${VERSION}/analytics-jars-${VERSION}-${BLD_NUM}.tar.gz \
  --acl public-read
