#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2
ARCH=$8

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

cd ${ROOT_DIR}/protoc-gen-go

DEPS=${WORKSPACE}/deps
GO_VER=$(gover_from_manifest)
CBDEP_TOOL_VER=1.1.6

CBDEP_BIN_CACHE=/home/couchbase/.cbdepscache/cbdep/${CBDEP_TOOL_VER}/cbdep-${CBDEP_TOOL_VER}-linux

if [[ ! -f ${CBDEP_BIN_CACHE} ]]; then
    if [ $(uname -s) = "Darwin" ]; then
        CBDEP_URL=https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VER}/cbdep-${CBDEP_TOOL_VER}-darwin-${ARCH}
    else
        CBDEP_URL=https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VER}/cbdep-${CBDEP_TOOL_VER}-linux-${ARCH}
    fi
    curl -o /tmp/cbdep ${CBDEP_URL}
else
   cp ${CBDEP_BIN_CACHE} /tmp/cbdep
fi

chmod +x /tmp/cbdep
/tmp/cbdep install -d "${DEPS}" golang ${GO_VER}

GOPATH=${WORKSPACE}
PATH=${DEPS}/go${GO_VER}/bin:$PATH

cd protoc-gen-go
go build
mkdir ${INSTALL_DIR}/bin
cp protoc-gen-go ${INSTALL_DIR}/bin
