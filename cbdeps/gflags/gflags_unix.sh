#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2

PACKAGE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${PACKAGE_DIR}/../../utilities/shell-utils.sh"

if [ "$(uname -s)" != "Darwin" ]; then
    # Build with GCC 13 on Linux
    export CXX=/opt/gcc-13.2.0/bin/g++
    export CC=/opt/gcc-13.2.0/bin/gcc
fi

cd "${ROOT_DIR}"
cmake -B build -S "${ROOT_DIR}/gflags" \
    -D CMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
    -D CMAKE_BUILD_TYPE=RelWithDebInfo \
    -D BUILD_SHARED_LIBS=OFF \
    -D CMAKE_POSITION_INDEPENDENT_CODE=ON

cd build
make -j8 install VERBOSE=1

rm -rf "${INSTALL_DIR}/lib/pkgconfig"
