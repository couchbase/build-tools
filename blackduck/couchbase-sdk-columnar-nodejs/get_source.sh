#!/bin/bash -ex

# example usage
# get_source.sh couchbase-sdk-columnar-nodejs 1.0.0 1.0.0 9999

# Set to "couchbase-sdk-columnar-nodejs", ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your
# scan-config.json specified a release key for this version, that value
# will be passed here
RELEASE=$2
# One of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

TARBALL="couchbase-columnar-${VERSION}.tgz"
SOURCE_DIR=couchbase-columnar

NODE_VER=20.9.0

# Make sure node and conan are present
cbdep install -d "${WORKSPACE}/extra" nodejs ${NODE_VER}
export PATH="${WORKSPACE}/extra/nodejs-${NODE_VER}/bin:$PATH"

# Lets only use git if we cannot find the source tarball on npm.
npm pack couchbase-columnar@$VERSION || true
if [ ! -f "${TARBALL}" ]; then
    if [ "$RELEASE" == "$VERSION" ] ; then
        RELEASE="main"
    fi
    echo "Version $VERSION does not exist on npm, checking out git repository and building tarball."
    git clone https://github.com/couchbaselabs/columnar-nodejs-client $SOURCE_DIR
    pushd $SOURCE_DIR
    git checkout $RELEASE
    git submodule update --init --recursive
    npm install --ignore-scripts
    mkdir packDestination
    npm pack --pack-destination packDestination
    TARBALL=$(find packDestination -type f -name "*.tgz")
    TARBALL=$(echo $TARBALL | cut -c 17-)
    popd
    mv $SOURCE_DIR/packDestination/$TARBALL .
    rm -rf $SOURCE_DIR
fi

tar -xvf $TARBALL
mkdir $SOURCE_DIR
mv package/* $SOURCE_DIR
pushd $SOURCE_DIR
# All columnar versions of SDK should have the BD manifest
mv deps/couchbase-cxx-client/couchbase-sdk-cxx-black-duck-manifest.yaml .
rm -rf deps
# package-lock.json + package.json should mean the BD
# detector search will satisfy the HIGH accuracy requirement
# SEE: https://sig-product-docs.synopsys.com/bundle/integrations-detect/page/components/detectors.html
npm install --ignore-scripts
rm -rf node_modules
popd
rm -rf package
rm $TARBALL
