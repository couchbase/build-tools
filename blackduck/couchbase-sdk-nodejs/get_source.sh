#!/bin/bash -ex

SCRIPT_ROOT="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# example usage
# get_source.sh couchbase-sdk-nodejs 4.2.8 4.2.8 9999

# Set to "couchbase-sdk-nodejs", ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your scan-config.json specified a release key for this version, 
# that value will be passed here
RELEASE=$2
# Onee of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

TARBALL="couchbase-${VERSION}.tgz"
SOURCE_DIR=couchnode

# Lets only use git if we cannot find the source tarball on npm.
npm pack couchbase@$VERSION || true
if [ ! -f "${TARBALL}" ]; then
    if [ "$RELEASE" == "$VERSION" ] ; then
        RELEASE="master"
    fi
    echo "Version $VERSION does not exist on npm, checking out git repository and building tarball."
    git clone https://github.com/couchbase/couchnode $SOURCE_DIR
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
# versions >= v4.2.8 also include C++ SDK's BD manifest in scan
if [ -f "couchbase-sdk-nodejs-black-duck-manifest.yaml" ]; then
    mv deps/couchbase-cxx-client/couchbase-sdk-cxx-black-duck-manifest.yaml .
    rm -rf deps
fi
# package-lock.json + package.json should mean the BD
# detector search will satisfy the HIGH accuracy requirement
# SEE: https://sig-product-docs.synopsys.com/bundle/integrations-detect/page/components/detectors.html
npm install --ignore-scripts
rm -rf node_modules
popd
rm -rf package
rm $TARBALL