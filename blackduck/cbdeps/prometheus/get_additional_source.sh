#!/bin/bash -e

PACKAGE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${PACKAGE_DIR}/../../../utilities/shell-utils.sh"

# This will also create
# `src/cbdeps::prometheus-black-duck-manifest.yaml` containing an entry
# for "Go programming language" with the appropriate version.
export PATH="$(${WORKSPACE}/build-tools/blackduck/jenkins/util/go-path-from-manifest.sh):$PATH"

# Install NodeJS
NODEJS_VER=$(annot_from_manifest NODEJS_VERSION)
cbdep install -d "${WORKSPACE}/extra" nodejs ${NODEJS_VER}
export PATH=${WORKSPACE}/extra/nodejs-${NODEJS_VER}/bin:${PATH}

# Install Node modules for anything without a package-lock.json
find . -name package.json | while read pkg; do
  pushd "$(dirname "$pkg")"
  if [ ! -e package-lock.json ]; then
    echo "Installing Node modules in $(pwd)"
    npm install
  else
    echo "Skipping Node modules installation in $(pwd) as package-lock.json exists"
  fi
  popd
done
