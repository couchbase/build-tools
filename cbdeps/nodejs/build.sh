#!/usr/bin/env bash
#
# This script assumes the following are installed on the system:
#   - curl
#
# Please ensure this is the case before running

NODE_VER=${1:-8.9.4}
ARCH=${2:-x64}

curl -o node-v${NODE_VER}-linux-${ARCH}.tar.gz https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-${ARCH}.tar.gz
tar zxf node-v${NODE_VER}-linux-${ARCH}.tar.gz

# Add unpacked nodeJS to path to install node-gyp
PATH=${WORKSPACE}/node-v${NODE_VER}-linux-${ARCH}/bin:${PATH}

# Install node-gyp; this will be placed in the nodeJS dependency tree
npm install -g node-gyp

# Create tarball
tar zcf node-${NODE_VER}-cb1-${PLATFORM}.tar.gz node-v${NODE_VER}-linux-${ARCH}
