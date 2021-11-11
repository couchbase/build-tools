#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PROFILE=$4
ARCH=$8

CBDEP_TOOL_VERSION=1.1.1

cd "${ROOT_DIR}"

SYSTEM=$(uname -s)
SYSTEM_LC=$(uname -s | tr '[:upper:]' '[:lower:]')

# Ensure we're using a new enough cmake
cmake --version

# If we're building for Server (or for SDK on MacOS), download the Server
# builds of OpenSSL (otherwise we assume the build agent has libssl available)
CBDEPS_DIR=$(pwd)/cbdeps
if [ ${PROFILE} == "server" -o ${SYSTEM} == "Darwin" ]; then
    export OPENSSL_VER=1.1.1k-3
    mkdir -p ${CBDEPS_DIR}
    cd ${CBDEPS_DIR}
    CBDEP_BIN=/home/couchbase/.cbdepscache/cbdep/${CBDEP_TOOL_VERSION}/cbdep-${CBDEP_TOOL_VERSION}-${SYSTEM_LC}
    if [ -x "${CBDEP_BIN}" ]; then
        cp -a "${CBDEP_BIN}" /tmp/bdep
    else
        curl -L https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VERSION}/cbdep-${CBDEP_TOOL_VERSION}-${SYSTEM_LC}-${ARCH} \
            -o /tmp/cbdep
        chmod 755 /tmp/cbdep
    fi
    /tmp/cbdep install -d ${CBDEPS_DIR} openssl ${OPENSSL_VER}
fi

cd "${ROOT_DIR}/grpc"
git submodule update --init --recursive

# Build grpc binaries and libraries. Specifying CMAKE_PREFIX_PATH is
# safe; if the downloaded CBDEPS_DIR doesn't exist, they'll just be
# ignored.
mkdir .build
cd .build
cmake -D CMAKE_BUILD_TYPE=RelWithDebInfo \
  -D CMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
  -D CMAKE_PREFIX_PATH="${CBDEPS_DIR}/openssl-${OPENSSL_VER}" \
  -DgRPC_INSTALL=ON \
  -DgRPC_BUILD_TESTS=OFF \
  -DgRPC_SSL_PROVIDER=package \
  ..
make -j8 install

exit 0
