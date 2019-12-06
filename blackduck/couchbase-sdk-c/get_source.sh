#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone git://github.com/couchbase/libcouchbase.git
pushd libcouchbase
if git rev-parse --verify --quiet $VERSION >& /dev/null
then
    echo "Tag $VERSION exists, checking it out"
    git checkout $VERSION
else
    echo "No tag $VERSION, assuming master"
fi
popd
# These are probably wrong per-version, but it's all we've got
git clone --branch OpenSSL_1_1_1d git://github.com/openssl/openssl.git thirdparty/openssl
git clone --branch release-2.1.8-stable git://github.com/libevent/libevent.git thirdparty/libevent
git clone --branch v1.24.1 git://github.com/libuv/libuv.git thirdparty/libuv
curl http://dist.schmorp.de/libev/Attic/libev-4.24.tar.gz | tar zx -C thirdparty
