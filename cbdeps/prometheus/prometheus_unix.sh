#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3

cd ${ROOT_DIR}

DEPS=${WORKSPACE}/deps
rm -rf ${DEPS}
CBDEP_TOOL_VER=1.0.1
GO_VER=1.14.2
NODEJS_VER=12.16.2

# Download cbdep, unless it's already available in the local .cbdepscache
OPSYS=$(uname -s | tr "[:upper:]" "[:lower:]")
CBDEP_BIN_CACHE=/home/couchbase/.cbdepscache/cbdep/${CBDEP_TOOL_VER}/cbdep-${CBDEP_TOOL_VER}-${OPSYS}

if [[ -f ${CBDEP_BIN_CACHE} ]]; then
    cp ${CBDEP_BIN_CACHE} /tmp/cbdep
else
    CBDEP_URL=https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VER}/cbdep-${CBDEP_TOOL_VER}-${OPSYS}
    curl -o /tmp/cbdep ${CBDEP_URL}
fi

chmod +x /tmp/cbdep

# Use cbdep to install golang
/tmp/cbdep install -d ${DEPS} golang ${GO_VER}
export PATH=${DEPS}/go${GO_VER}/bin:${PATH}

# Use cbdep to install nodejs
/tmp/cbdep install -d ${DEPS} nodejs ${NODEJS_VER}
export PATH=${DEPS}/nodejs-${NODEJS_VER}/bin:${PATH}

# Use nodejs to install yarn
npm install -g yarn

# And, finally, build prometheus
export GOPATH=$(pwd)/goproj
cd goproj/src/github.com/prometheus/prometheus
if [[ ${PLATFORM} =~ ^windows ]]; then
    echo "CROSS COMPILING FOR WINDOWS!"
    export GOOS=windows
    export GOARCH=amd64
    BINARY=prometheus.exe
else
    BINARY=prometheus
fi
make build

# Install final binary
mkdir ${INSTALL_DIR}/bin
cp ${BINARY} ${INSTALL_DIR}/bin
