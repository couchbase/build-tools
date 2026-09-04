#!/bin/bash -ex

# blackduck complains about node_modules directory if it is not there,
# so run "npm" install for all packages.

rm -rf couchbase-cloud/cmd/cp-ui couchbase-cloud/cmd/cp-ui-tests couchbase-cloud/cmd/cp-ui-docs-screenshots
for dir in $(find . -name package.json \
  -exec dirname {} \;)
do
    pushd $dir
    # Try to identify an appropriate version of node from build-and-deliver-predev.yml
    # based on the contents of package.json
    REQUIRED_NODE_VERSION=$(jq -re '.engines.node // ""' package.json | sed 's/[^0-9.]//g')
    if [[ "${REQUIRED_NODE_VERSION}" == \>=* ]]; then
      MIN_VERSION=$(echo "${REQUIRED_NODE_VERSION}" | cut -d ' ' -f 2)
      NODE_VER=$(echo "${NODE_VERSIONS}" | awk -v min_ver="${MIN_VERSION}" -F. '$1 >= min_ver' | sort -V | head -n 1)
    elif [[ "${REQUIRED_NODE_VERSION}" == \<=* ]]; then
      MAX_VERSION=$(echo "${REQUIRED_NODE_VERSION}" | cut -d ' ' -f 2)
      NODE_VER=$(echo "${NODE_VERSIONS}" | awk -v max_ver="${MAX_VERSION}" -F. '$1 <= max_ver' | sort -V | tail -n 1)
    elif [[ "${REQUIRED_NODE_VERSION}" == ==* ]]; then
      NODE_VER=${REQUIRED_NODE_VERSION}
    else
      # If we got here package.json either specified a raw version number or nothing at all
      # so we just match what it expects (i.e. full version or latest)
      NODE_VER=$(echo "${NODE_VERSIONS}" | grep "^${REQUIRED_NODE_VERSION}" | tail -n 1)
    fi

    if [ ! -d "${WORKSPACE}/extra/nodejs-${NODE_VER}" ]; then
        cbdep install -d "${WORKSPACE}/extra" nodejs ${NODE_VER}
    fi

    export PATH="${WORKSPACE}/extra/nodejs-${NODE_VER}/bin:$PATH"

    # cp-ui-v3 ships .npmrc.example rather than .npmrc
    if [ ! -f .npmrc -a -f .npmrc.example ]; then
        cp .npmrc.example .npmrc
    fi

    # .npmrc interpolates ${GITHUB_TOKEN} for @couchbasecloud packages on
    # npm.pkg.github.com. Passed per-command with xtrace off so it neither
    # hits the build log nor run_script's .env dump.
    set +x
    GITHUB_TOKEN=$(cat ~/.ssh/blackduck-cloud-package-read) npm install
    set -x
    popd
done
