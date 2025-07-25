#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3
PROFILE=$4
ARCH=$8
BD_MANIFEST=$9

PACKAGE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "${ROOT_DIR}"

SYSTEM=$(uname -s)
SYSTEM_LC=$(uname -s | tr '[:upper:]' '[:lower:]')

# CMake 4.0.0 can't build c-ares anymore, so force an older version
cbdep install -d $(pwd)/tools cmake 3.31.0
export PATH=$(pwd)/tools/cmake-3.31.0/bin:${PATH}

# Need C++17
if [ $PLATFORM = "linux" ]; then
    export CC=/opt/gcc-13.2.0/bin/gcc
    export CXX=/opt/gcc-13.2.0/bin/g++
fi

# If we're building for Server (or for SDK on MacOS), download the Server
# builds of OpenSSL (otherwise we assume the build agent has libssl available)
CBDEPS_DIR=$(pwd)/cbdeps
if [ ${PROFILE} == "server" -o ${SYSTEM} == "Darwin" ]; then
    export OPENSSL_VER=3.5.1-1
    mkdir -p ${CBDEPS_DIR}
    cd ${CBDEPS_DIR}
    cbdep --platform ${PLATFORM} install -d ${CBDEPS_DIR} openssl ${OPENSSL_VER}
fi

cd "${ROOT_DIR}/grpc"
git submodule update --init --recursive

# CBD-6299: need newer c-ares, but grpc hasn't gotten around to it yet
# (https://github.com/grpc/grpc/issues/39026). Pull the newer version
# here.
pushd third_party/cares/cares
git fetch origin
git checkout v1.34.5
popd

# Construct Black Duck manifest, if requested.
if [ -n "${BD_MANIFEST}" ]; then
  # This is all a bit hacky, but we prefer to try to extract this from
  # the code itself rather than manually keep tabs. Each submodule names
  # their tags differently, and Black Duck has its own conventions, so
  # this will surely not always work.
  function get_tag() {
    local dir=$1
    local no_strip_v=$2

    local strip_prefix="v"
    if [ -n "${no_strip_v}" ]; then
      strip_prefix="ignore-unlikely-prefix"
    fi

    git -C $1 describe --tags --long | \
      sed -e "s/^${strip_prefix}//" -e 's/-[0-9]*-g[0-9a-f]*$//'
  }

  GRPC_VERSION=$(get_tag .)
  ABSEIL_VERSION=$(get_tag third_party/abseil-cpp)
  CARES_VERSION=$(get_tag third_party/cares/cares)
  PROTOBUF_VERSION=$(get_tag third_party/protobuf)
  RE2_VERSION=$(get_tag third_party/re2 describe | sed -e 's/-//g')
  ZLIB_VERSION=$(get_tag third_party/zlib no_strip_v)
  cat "${PACKAGE_DIR}/blackduck/black-duck-manifest.yaml.in" \
    | sed -e "s/@@GRPC_VERSION@@/${GRPC_VERSION}/g" \
    | sed -e "s/@@ABSEIL_VERSION@@/${ABSEIL_VERSION}/g" \
    | sed -e "s/@@CARES_VERSION@@/${CARES_VERSION}/g" \
    | sed -e "s/@@PROTOBUF_VERSION@@/${PROTOBUF_VERSION}/g" \
    | sed -e "s/@@RE2_VERSION@@/${RE2_VERSION}/g" \
    | sed -e "s/@@ZLIB_VERSION@@/${ZLIB_VERSION}/g" \
    > "${BD_MANIFEST}"

fi

# Build grpc binaries and libraries. Specifying CMAKE_PREFIX_PATH is
# safe; if the downloaded CBDEPS_DIR doesn't exist, they'll just be
# ignored.
mkdir -p .build
cd .build
cmake \
  -D CMAKE_CXX_STANDARD=17 \
  -D CMAKE_BUILD_TYPE=RelWithDebInfo \
  -D CMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
  -D CMAKE_INSTALL_LIBDIR=lib \
  -D CMAKE_PREFIX_PATH="${CBDEPS_DIR}/openssl-${OPENSSL_VER}" \
  -D RE2_BUILD_TESTING=OFF \
  -DgRPC_INSTALL=ON \
  -DgRPC_BUILD_TESTS=OFF \
  -DgRPC_SSL_PROVIDER=package \
  ..
make -j8 install

exit 0
