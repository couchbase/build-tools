#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3

cd ${ROOT_DIR}/libtirpc
sh ./autogen.sh
./configure --prefix=${INSTALL_DIR} --disable-static --disable-gssapi
make -j4
make install

# We don't want the pkgconfig stuff - doesn't work for things that might
# be installed in various directories
rm -rf ${INSTALL_DIR}/lib/pkgconfig
