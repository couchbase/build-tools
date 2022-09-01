#!/bin/bash -ex

## blackduck complains about node_modules directory if it is not there.

NODE_VERSION=16.15.1
cbdep install -d ${WORKSPACE}/extra nodejs ${NODE_VERSION}
export PATH=${WORKSPACE}/extra/nodejs-${NODE_VERSION}/bin:$PATH

for dir in couchbase-cloud/scripts/insomnia-plugin-cb-token-auth \
           couchbase-cloud/clientSDKSamples/javascript \
           couchbase-cloud/cmd/cp-jungle-jim/go-playground
do
    pushd $dir
    npm install
    popd
done
