#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

# There's no consistent place across versions to grab a cmake version from
# the source, at time of writing 3.28.3 is the latest release
CMAKE_VERSION=3.28.3
cbdep install -d "${WORKSPACE}/extra" cmake ${CMAKE_VERSION}
export PATH="${WORKSPACE}/extra/cmake-${CMAKE_VERSION}/bin:${PATH}"

# current repo, do not remove:
# github.com/couchbase/couchbase-php-client

PHP_VERSION=8.1.4-cb1

cbdep install php-nts ${PHP_VERSION}
export PATH="/tmp/php/php-nts-${PHP_VERSION}/bin:${PATH}"

case "$VERSION" in
    3.1*|3.2*)
        REPO=ssh://git@github.com/couchbase/php-couchbase.git
        VERSION_PREFIX=v
        ;;
    *)
        REPO=ssh://git@github.com/couchbase/couchbase-php-client.git
        VERSION_PREFIX=
        ;;
esac

git clone --recurse-submodules $REPO couchbase-php-client
pushd couchbase-php-client
TAG="${VERSION_PREFIX}${VERSION}"
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi

TARBALL=
IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
if (( MAJOR > 4 || (MAJOR == 4 && MINOR >= 2) ))
then
    gem install --user-install --no-document nokogiri
    BUILD_NUMBER=0 ruby bin/package.rb
    TARBALL=$(ls -1 couchbase-*.tgz | head -1)
    mv $TARBALL ../
else
    # Work-around for Black Duck Detect bug
    sed '/DOCTYPE/d' package.xml
fi

popd

if [[ ! -z "${TARBALL}" ]]
then
    tar xf ${TARBALL}
    TARBALL_CONTENTS_DIR=$(basename ${TARBALL} .tgz)
    for MANIFEST in $(find . -name 'couchbase-sdk-php-black-duck-manifest.yaml')
    do
        cp ${MANIFEST} ${TARBALL_CONTENTS_DIR}
    done

    rm ${TARBALL}
    rm -rf couchbase-php-client
    mv ${TARBALL_CONTENTS_DIR} couchbase-php-client
    cp package.xml couchbase-php-client/
    rm -rf couchbase-php-client/src/deps
fi
