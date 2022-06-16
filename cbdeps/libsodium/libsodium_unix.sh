#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2

cd ${ROOT_DIR}/libsodium
./configure --prefix=${INSTALL_DIR}
make && make check
make install

# For MacOS, tweak install_name
if [ $(uname -s) = "Darwin" ]; then
    install_name_tool -id @rpath/libsodium.dylib ${INSTALL_DIR}/lib/libsodium.dylib
fi

rm -rf ${INSTALL_DIR}/lib/pkgconfig
rm -f ${INSTALL_DIR}/lib/libsodium.la
