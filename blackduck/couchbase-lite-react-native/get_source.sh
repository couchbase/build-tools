#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

repo init -u https://github.com/couchbase/build-manifests -m ${PRODUCT}/${VERSION}/${VERSION}.xml
repo sync
rm -rf product-texts cbbuild

NODE_VERSION=$(curl -s https://nodejs.org/dist/index.json | \
    jq -r '.[] | select(.lts != false) | .version' | \
    head -1 | sed 's/^v//')
cbdep install nodejs ${NODE_VERSION} -d ${WORKSPACE}
export PATH=${WORKSPACE}//nodejs-${NODE_VERSION}/bin:${PATH}
# cleanup to reduce scan noise
rm -rf ${PRODUCT}/expo-example
