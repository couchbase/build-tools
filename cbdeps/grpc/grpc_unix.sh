#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PROFILE=$4

cd "${ROOT_DIR}"

SYSTEM=$(uname -s)
SYSTEM_LC=$(uname -s | tr '[:upper:]' '[:lower:]')

# Ensure we're using a new enough cmake
mkdir -p tools
cd tools
if [ "${SYSTEM}" == "Darwin" ]; then
    CMAKE_PATH=cmake/CMake.app/Contents/bin
else
    CMAKE_PATH=cmake/bin
fi
if [ ! -x ${CMAKE_PATH}/cmake ]; then
    CMAKE_VERSION=3.18.1
    curl -L https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-${SYSTEM}-x86_64.tar.gz | tar xzf -
    mv cmake-* cmake
fi
export PATH=$(pwd)/${CMAKE_PATH}:${PATH}
cmake --version

# If we're building for Server (or for SDK on MacOS), download the Server
# builds of OpenSSL (otherwise we assume the build agent has libssl available)
CBDEPS_DIR=$(pwd)/cbdeps
if [ ${PROFILE} == "server" -o ${SYSTEM} == "Darwin" ]; then
    export OPENSSL_VER=1.1.1d-cb2
    mkdir -p ${CBDEPS_DIR}
    cd ${CBDEPS_DIR}
    curl -L https://packages.couchbase.com/cbdep/0.9.16/cbdep-0.9.16-${SYSTEM_LC} \
      -o cbdep
    chmod 755 cbdep
    ./cbdep install -d ${CBDEPS_DIR} openssl ${OPENSSL_VER}
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
