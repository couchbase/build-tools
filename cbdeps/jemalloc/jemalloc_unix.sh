#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2

cd ${ROOT_DIR}/jemalloc

./autogen.sh
CPPFLAGS=-I/usr/local/include ./configure \
    --prefix=${INSTALL_DIR} \
    --with-jemalloc-prefix=je_ \
    --disable-cache-oblivious \
    --disable-zone-allocator \
    --enable-prof
make build_lib_shared
make install_lib_shared install_include install_bin

if [ $(uname -s) = "Darwin" ]; then
    install_name_tool -id @rpath/libjemalloc.2.dylib ${INSTALL_DIR}/lib/libjemalloc.2.dylib
fi
