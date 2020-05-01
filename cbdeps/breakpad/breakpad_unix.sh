#!/bin/bash -e
#
# NOTE: Currently building on macOS is not supported

INSTALL_DIR=$1
ROOT_DIR=$2

cd ${ROOT_DIR}/breakpad

export LDFLAGS="-Wl,-rpath,'\$\$ORIGIN/../lib'"

./configure --prefix=${INSTALL_DIR}
make
make install
