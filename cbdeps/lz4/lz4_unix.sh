#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2

cd "${ROOT_DIR}"
mkdir lz4build
cd lz4build

cmake \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_MACOSX_RPATH=1 \
    -DCMAKE_INSTALL_LIBDIR=lib \
    "${ROOT_DIR}/lz4/build/cmake"
ninja install

cd "${INSTALL_DIR}"
rm -rf lib/pkgconfig
rm -rf share
