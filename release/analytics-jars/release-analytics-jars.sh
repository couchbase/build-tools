#!/bin/bash -ex

RELEASE=$1
VERSION=$2
BLD_NUM=$3

# Download named build (use Ubuntu 18 - will need to update in far future
# when we no longer support Ubuntu 18)
curl -L http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/couchbase-server-enterprise_${VERSION}-${BLD_NUM}-ubuntu18.04_amd64.deb -o couchbase-server.deb

# Extract jar contents
ar x couchbase-server.deb
tar xf data.tar.xz --wildcards --no-wildcards-match-slash --strip-components 5 \
  './opt/couchbase/lib/cbas/repo/*.jar' './opt/couchbase/lib/cbas/repo/jars/*.jar'

pushd repo
if [ -f cbas-install-*.jar ]; then
  # starting in 7.0.1, analytics utilizes a manifest jar for its classpath; extract that to determine the jars we need
  # to include
  # TODO(mblow): this will need to be reworked if we ever have jars with a space in the name...
  unzip -p cbas-install-*.jar  META-INF/MANIFEST.MF | sed 's/^ /@@/g' | sed 's/@@@/#/g' | grep '\(^Class-Path\|^@@\)' \
    | tr -d '\r' | tr -d '\n' | sed -e 's/@@//g' -e 's/^Class-Path: //' | xargs -n1 \
    | tar cvzf ../analytics-jars-${VERSION}-${BLD_NUM}.tar.gz -T - cbas-install-*.jar
else
  tar cvzf ../analytics-jars-${VERSION}-${BLD_NUM}.tar.gz *.jar
fi
popd

# Publish to S3
aws s3 cp analytics-jars-${VERSION}-${BLD_NUM}.tar.gz \
  s3://packages.couchbase.com/releases/${VERSION}/analytics-jars-${VERSION}-${BLD_NUM}.tar.gz \
  --acl public-read
