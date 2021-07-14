#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2

cd "${ROOT_DIR}/liburing"
./configure --prefix="${INSTALL_DIR}"
make -j8
make install

rm -rf "${INSTALL_DIR}/man" "${INSTALL_DIR}/lib/pkgconfig"
