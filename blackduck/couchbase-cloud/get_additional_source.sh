#!/bin/bash -ex

## blackduck complains about node_modules directory if it is not there.

NODE_VERSION=16.15.1
cbdep install -d ${WORKSPACE}/extra nodejs ${NODE_VERSION}
export PATH=${WORKSPACE}/extra/nodejs-${NODE_VERSION}/bin:$PATH

pushd couchbase-cloud/scripts/insomnia-plugin-cb-token-auth
npm install
popd
pushd couchbase-cloud/clientSDKSamples/javascript
npm install
popd
