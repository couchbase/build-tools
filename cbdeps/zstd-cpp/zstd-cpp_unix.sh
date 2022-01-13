#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2

BUILD_DIR=build/cmake/build

cd ${ROOT_DIR}/zstd-cpp

mkdir -p ${BUILD_DIR}
cd ${BUILD_DIR}
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ..
cmake --build .
cmake --install . --prefix ${INSTALL_DIR}

# lib dir is lib64 on linux
[ -d "${INSTALL_DIR}/lib64" ] \
    && mv "${INSTALL_DIR}/lib64" "${INSTALL_DIR}/lib"

rm -rf \
    "${INSTALL_DIR}/bin" \
    "${INSTALL_DIR}/lib/cmake" \
    "${INSTALL_DIR}/lib/pkgconfig" \
    "${INSTALL_DIR}/share"
