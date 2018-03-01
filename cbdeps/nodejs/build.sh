#!/usr/bin/env bash
#
# This script assumes the following are installed on the system:
#   - curl
#
# Please ensure this is the case before running

set -e

NODE_VER=${1:-8.9.4}
ARCH=${2:-x64}

SYSNAME=$(uname -s | awk '{print tolower($0)}')

curl -o node-v${NODE_VER}-${SYSNAME}-${ARCH}.tar.gz https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-${SYSNAME}-${ARCH}.tar.gz
tar zxf node-v${NODE_VER}-${SYSNAME}-${ARCH}.tar.gz
mv node-v${NODE_VER}-${SYSNAME}-${ARCH} node-v${NODE_VER}

# Add unpacked nodeJS to path to install node-gyp
PATH=${WORKSPACE}/node-v${NODE_VER}/bin:${PATH}

# Install node-gyp; this will be placed in the nodeJS dependency tree
npm install -g node-gyp

# Create tarball
tar zcf node-${NODE_VER}-cb1-${PLATFORM}-${ARCH}.tar.gz node-v${NODE_VER}
rm -rf node-v${NODE_VER}
