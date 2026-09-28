#!/bin/bash -ex

NODE_VERSION=$(curl -s https://nodejs.org/dist/index.json | \
    jq -r '.[] | select(.lts != false) | .version' | \
    head -1 | sed 's/^v//')
cbdep install -d ${WORKSPACE}/extra nodejs ${NODE_VERSION}
export PATH=${WORKSPACE}/extra/nodejs-${NODE_VERSION}/bin:${PATH}

rm -rf cbbuild product-texts manifest.xml
pushd couchbase-lite-js
rm -rf couchbase-lite-js/test
export PATH=`pwd`/node_modules/.bin:$PATH
npm ci --omit=dev
npm install --production
