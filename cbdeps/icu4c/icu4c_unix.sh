#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2
PROFILE=$4

cd ${ROOT_DIR}/icu/icu4c/source
./runConfigureICU --enable-debug Linux/gcc
make -j8
make install prefix="${INSTALL_DIR}"

rm -rf "${INSTALL_DIR}/bin"
rm -rf "${INSTALL_DIR}/lib/icu"
rm -rf "${INSTALL_DIR}/lib/pkgconfig"
rm -rf "${INSTALL_DIR}/sbin"
rm -rf "${INSTALL_DIR}/share"
