#!/bin/bash -e

INSTALL_DIR=$1

DEPS=${WORKSPACE}/deps
GO_VERS=1.11.5

if [ $(uname -s) = "Darwin" ]; then
    CBDEP_URL=https://packages.couchbase.com/cbdep/0.9.3/cbdep-0.9.3-darwin
else
    CBDEP_URL=https://packages.couchbase.com/cbdep/0.9.3/cbdep-0.9.3-linux
fi

curl -o /tmp/cbdep ${CBDEP_URL}
chmod +x /tmp/cbdep
/tmp/cbdep install -d "${DEPS}" golang ${GO_VERS}

GOPATH=${WORKSPACE}
PATH=${DEPS}/go1.11.5/bin:$PATH

cd protoc-gen-go
go build
mkdir ${INSTALL_DIR}/bin
cp protoc-gen-go ${INSTALL_DIR}/bin
