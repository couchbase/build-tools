#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2

cd ${ROOT_DIR}/zlib
./configure --prefix=${INSTALL_DIR}
make
make install

# For MacOS, tweak install_name
if [ $(uname -s) = "Darwin" ]; then
    install_name_tool -id @rpath/libz.1.dylib ${INSTALL_DIR}/lib/libz.1.dylib
fi
