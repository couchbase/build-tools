#!/bin/bash -e
#
# NOTE: Currently building on macOS is not supported

INSTALL_DIR=$1

export LDFLAGS="-Wl,-rpath,'\$\$ORIGIN/../lib'"

autoreconf -i
./configure --prefix=${INSTALL_DIR}
make
make install
