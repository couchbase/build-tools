#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2

# libsodium 1.0.21 introduced "crypto_ipcrypt"
# The compiler complains about NEON type-strictness error
# expected 'uint8x16_t' but argument is of type 'BlockVec' {aka 'uint64x2_t'}
if [ $(uname -m) == "aarch64" ]; then
    export CFLAGS="-O3 -flax-vector-conversions"
fi

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
