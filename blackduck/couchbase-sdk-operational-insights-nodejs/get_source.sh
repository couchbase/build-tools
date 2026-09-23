#!/bin/bash -ex

# example usage
# get_source.sh couchbase-sdk-operational-insights-nodejs 1.0.0 1.0.0 9999

# Set to "couchbase-sdk-operational-insights-nodejs", ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your
# scan-config.json specified a release key for this version, that value
# will be passed here
RELEASE=$2
# One of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

PACKAGE=couchbase-operational-insights
REPO=https://github.com/couchbase/operational-insights-nodejs-client
SOURCE_DIR=couchbase-operational-insights
TARBALL="${PACKAGE}-${VERSION}.tgz"

NODE_VER=22.12.0

# Make sure node is present
cbdep install -d "${WORKSPACE}/extra" nodejs ${NODE_VER}
export PATH="${WORKSPACE}/extra/nodejs-${NODE_VER}/bin:$PATH"

# Only build from git if the version is not on npm yet.
npm pack "${PACKAGE}@${VERSION}" || true
if [ ! -f "${TARBALL}" ]; then
    # A version key without its own release (an upcoming version) scans main.
    if [ "${RELEASE}" == "${VERSION}" ]; then
        RELEASE=main
    fi
    echo "Version ${VERSION} does not exist on npm, building a tarball from ${RELEASE}."
    git clone --depth 1 --branch "${RELEASE}" "${REPO}" "${SOURCE_DIR}"
    # npm pack runs the prepare script, which builds with the dev dependencies.
    (cd "${SOURCE_DIR}" && npm install --ignore-scripts && npm pack --pack-destination ..)
    rm -rf "${SOURCE_DIR}"
    TARBALL=$(ls "${PACKAGE}"-*.tgz)
fi

tar -xf "${TARBALL}"
mv package "${SOURCE_DIR}"
rm "${TARBALL}"
