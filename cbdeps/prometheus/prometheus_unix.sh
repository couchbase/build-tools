#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

cd ${ROOT_DIR}

DEPS=${WORKSPACE}/deps
rm -rf ${DEPS}
NODEJS_VER=16.5.0

# Extract GOVERSION from manifest, and install using cbdep
GO_VER=$(gover_from_manifest)
cbdep install -d ${DEPS} golang ${GO_VER}
export PATH=${DEPS}/go${GO_VER}/bin:${PATH}

# Use cbdep to install nodejs
cbdep install -d ${DEPS} nodejs ${NODEJS_VER}
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
