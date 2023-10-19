#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2

cd "${ROOT_DIR}/openblas"
mkdir build
cd build
cmake -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" ..
make -j8 install

cd "${INSTALL_DIR}"
if [ -d lib64 ]; then
  mv lib64 lib
fi
