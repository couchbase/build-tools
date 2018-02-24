#!/usr/bin/env bash
#
# This script assumes the following are installed on the system:
#   - curl
#   - git
#
# and that the Python 2.7 and nodeJS dependencies have already been built
# and are in the appropriate path
#
# Please ensure this is the case before running

NODE_VER=${1:-8.9.4}
ARCH=${2:-x64}

git clone https://github.com/couchbaselabs/cbsdkbb
git clone https://github.com/couchbase/couchnode

# Set environment variables to be able to access the proper dependencies
BBSDK=${WORKSPACE}/cbsdkbb
PATH=${WORKSPACE}/deps/node-v${NODE_VER}-linux-${ARCH}/bin:${WORKSPACE}/deps/relocatable-python/dist/bin:${PATH}

# Initialize some more environment variables
cd couchnode/
. ${BBSDK}/common/env ${ARCH}
. ${BBSDK}/njs/env ${NODE_VER}

# Install dependencies (found in package-lock.json file in couchnode)
# and then create pre-built library
npm install --ignore-scripts --unsafe-perm
export npm_config_loglevel="silly"
node ./node_modules/prebuild/bin.js -b ${NODE_VER} --verbose --force
