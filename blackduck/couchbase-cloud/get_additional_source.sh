#!/bin/bash -ex

## blackduck complains about node_modules directory if it is not there.

NODE_VERSION=16.15.1
cbdep install -d ${WORKSPACE}/extra nodejs ${NODE_VERSION}
export PATH=${WORKSPACE}/extra/nodejs-${NODE_VERSION}/bin:$PATH

rm -rf couchbase-cloud/cmd/cp-ui couchbase-cloud/cmd/cp-ui-tests couchbase-cloud/cmd/cp-ui-docs-screenshots
for dir in $(find . -name package.json \
  -exec dirname {} \;)
do
    pushd $dir
    npm install
    popd
done
