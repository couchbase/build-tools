#!/bin/bash -e

INSTALL_DIR=$1

# Unix build without gyp
./autogen.sh
./configure --disable-silent-rules --prefix=${INSTALL_DIR}
make
make install

# For MacOS, tweak install_name
if [ $(uname -s) = "Darwin" ]; then
    install_name_tool -id @rpath/libuv.1.dylib ${INSTALL_DIR}/lib/libuv.1.dylib
fi
