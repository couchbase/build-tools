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

set -e

NODE_VER=${1:-8.9.4}
ARCH=${2:-x64}

if [[ "$(uname -s)" == "Darwin" ]]; then
    PYTHON_BASEPATH=/Library/Frameworks/Python.framework/Versions/2.7/bin
else
    PYTHON_BASEPATH=${WORKSPACE}/deps/relocatable-python/dist/bin
fi

# Set environment variables to be able to access the proper dependencies
PATH=${WORKSPACE}/deps/node-v${NODE_VER}/bin:${PYTHON_BASEPATH}:${PATH}

cd couchnode/

# Install dependencies (found in package-lock.json file in couchnode)
# and then create pre-built library
npm install --ignore-scripts --unsafe-perm
export npm_config_loglevel="silly"
node ./node_modules/prebuild/bin.js -b ${NODE_VER} --verbose --force
