#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com/couchbaselabs/couchbase-rs.git

RUST_VERSION=$(curl -s https://static.rust-lang.org/dist/channel-rust-stable.toml | awk '/^\[pkg.rust\]/{flag=1} flag && /^version =/{print; exit}' | sed 's/version = "\(.*\)"/\1/' | cut -d' ' -f1)

cbdep install -d "${WORKSPACE}/extra" rust ${RUST_VERSION}
export PATH="${WORKSPACE}/extra/rust-${RUST_VERSION}/bin:${PATH}"

pushd couchbase-rs
if git rev-parse --verify --quiet ${VERSION} >& /dev/null
then
    echo "Tag ${VERSION} exists, checking it out"
    git checkout ${VERSION}
else
    echo "No tag ${VERSION}, assuming main"
fi
popd