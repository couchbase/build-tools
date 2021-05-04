#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2

cd ${ROOT_DIR}/libuv

# Unix build without gyp
./autogen.sh
./configure --disable-silent-rules --prefix=${INSTALL_DIR}
make
make install

# Clean up unwanted stuff
(
    cd ${INSTALL_DIR}/lib
    rm -rf pkgconfig libuv.la libuv.a
)

# For MacOS, tweak install_name
if [ $(uname -s) = "Darwin" ]; then
    install_name_tool -id @rpath/libuv.1.dylib ${INSTALL_DIR}/lib/libuv.1.dylib
fi
