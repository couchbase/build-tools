#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2

cd "${ROOT_DIR}/ncurses"

./configure --with-shared --with-termlib --with-versioned-syms --prefix=

make install DESTDIR="${INSTALL_DIR}"
