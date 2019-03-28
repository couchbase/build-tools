#!/bin/bash -e

INSTALL_DIR=$1

DEPS=${WORKSPACE}/deps
GO_VERS=1.11.5
CBDEP_TOOL_VERS=0.9.3

CBDEP_BIN_CACHE=/home/couchbase/.cbdepscache/cbdep/${CBDEP_TOOL_VERS}/cbdep-${CBDEP_TOOL_VERS}-linux

if [[ ! -f ${CBDEP_BIN_CACHE} ]]; then
    if [ $(uname -s) = "Darwin" ]; then
        CBDEP_URL=https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VERS}/cbdep-${CBDEP_TOOL_VERS}-darwin
    else
        CBDEP_URL=https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VERS}/cbdep-${CBDEP_TOOL_VERS}-linux
    fi
    curl -o /tmp/cbdep ${CBDEP_URL}
else
   cp ${CBDEP_BIN_CACHE} /tmp/cbdep
fi

chmod +x /tmp/cbdep
/tmp/cbdep install -d "${DEPS}" golang ${GO_VERS}

GOPATH=${WORKSPACE}
PATH=${DEPS}/go1.11.5/bin:$PATH

cd protoc-gen-go
go build
mkdir ${INSTALL_DIR}/bin
cp protoc-gen-go ${INSTALL_DIR}/bin
