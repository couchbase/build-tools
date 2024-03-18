#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

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
case "$VERSION" in
    4.2.*)
        gem install --user-install --no-document nokogiri
        ruby bin/package.rb
        TARBALL=$(ls -1 couchbase-*.tgz | head -1)
        mv $TARBALL ../
        ;;

    *)
        # Work-around for Black Duck Detect bug
        sed '/DOCTYPE/d' package.xml
        ;;
esac

popd

if [[ ! -z "${TARBALL}" ]]
then
    tar xf ${TARBALL}
    rm ${TARBALL}
    rm -rf couchbase-php-client
    mv couchbase-* couchbase-php-client
    cp package.xml couchbase-php-client/
fi
