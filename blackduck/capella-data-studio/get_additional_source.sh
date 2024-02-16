#!/bin/bash -ex

# install nodejs
NODE_VER=20.9.0
cbdep install -d "${WORKSPACE}/extra" nodejs ${NODE_VER}
export PATH="${WORKSPACE}/extra/nodejs-${NODE_VER}/bin:$PATH"

# blackduck complains about node_modules directory if it is not there,
# so run "npm" install for all packages.

for dir in $(find . -name package.json \
  -exec dirname {} \;)
do
    pushd $dir
    npm install
    popd
done
