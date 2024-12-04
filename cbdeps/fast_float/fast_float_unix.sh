#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2

if [ "$(uname -s)" != "Darwin" ]; then
    # Build with GCC 13 on Linux
    export CXX=/opt/gcc-13.2.0/bin/g++
    export CC=/opt/gcc-13.2.0/bin/gcc
fi

cd "${ROOT_DIR}"
cmake -B build -S "${ROOT_DIR}/fast_float" \
    -D CMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
    -D CMAKE_BUILD_TYPE=RelWithDebInfo \
    -D BUILD_SHARED_LIBS=OFF \
    -D FASTFLOAT_CXX_STANDARD=17 \
    -D CMAKE_POSITION_INDEPENDENT_CODE=ON
cd build

make -j8 install VERBOSE=1

rm -rf ${INSTALL_DIR}/share
