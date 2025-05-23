#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3
PROFILE=$4
ARCH=$8

if [ "${PLATFORM}" = "linux" ]; then
    export CC=/opt/gcc-13.2.0/bin/gcc
    export CXX=/opt/gcc-13.2.0/bin/g++
    export cxx_flags="-fPIC -fvisibility=hidden"

    if [ "${ARCH}" = "x86_64"  -a "${PROFILE}" = "avx2" ]; then
        export cxx_flags="-march=x86-64-v3 ${cxx_flags}"
    fi
fi

cd ${ROOT_DIR}/simdutf
rm -rf build
mkdir build
cd build
set -x
cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_CXX_FLAGS="${cxx_flags}" \
    -DSIMDUTF_BENCHMARKS=OFF \
    -DSIMDUTF_TESTS=OFF \
    -DSIMDUTF_ICONV=OFF \
    -DSIMDUTF_TOOLS=OFF \
    ..
ninja install

rm -rf ${INSTALL_DIR}/lib/pkgconfig
