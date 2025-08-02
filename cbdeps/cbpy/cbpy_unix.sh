#!/bin/bash -ex

# Copyright 2021-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.

INSTALL_DIR=$1
ROOT_DIR=$2
VERSION=$6

# cbpy version == included python version
PYTHON_VERSION=${VERSION}
UV_VERSION=0.5.2
SRC_DIR=${ROOT_DIR}/build-tools/cbdeps/cbpy

if [ $(uname -s) = "Darwin" ]; then
    platform=macosx-$(uname -m)
else
    platform=linux-$(uname -m)
fi

# Install UV
cbdep install -d . uv ${UV_VERSION}
export PATH=$(pwd)/uv-${UV_VERSION}/bin:${PATH}

# Ask UV to install python
uv python install ${PYTHON_VERSION}

# Copy that python installation to INSTALL_DIR, and remove the magic
# file that prevents `uv pip` from manipulating it
cp -a $(dirname $(uv python find ${PYTHON_VERSION}))/.. ${INSTALL_DIR}
find ${INSTALL_DIR} -name EXTERNALLY-MANAGED -delete
PYTHON=${INSTALL_DIR}/bin/python3

# Compile our requirements.txt into a locked form - save this file in the
# installation directory for use by Black Duck
REQ_FILE=${INSTALL_DIR}/lib/cb-requirements.txt
uv pip compile --python ${PYTHON} --universal "${SRC_DIR}/cb-dependencies.txt" > ${REQ_FILE}

# Remove pip and setuptools from cbpy
uv pip uninstall --python ${PYTHON} pip setuptools

# Install our desired dependencies
uv pip install --python ${PYTHON} --no-build -r ${REQ_FILE}

# Prune installation
cd ${INSTALL_DIR}
rm -rf include share
find . -type d -name __pycache__ -print0 | xargs -0 rm -rf

cd ${INSTALL_DIR}/bin
rm -f 2to3* idle* natsort normalizer pydoc*

cd ${INSTALL_DIR}/lib
rm -rf itcl* pkgconfig tcl* tk* Tix*

cd ${INSTALL_DIR}/lib/python*
rm -rf ensurepip

# Quick installation test
"${INSTALL_DIR}/bin/python" "${SRC_DIR}/test_cbpy.py"
