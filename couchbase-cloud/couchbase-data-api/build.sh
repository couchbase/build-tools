#!/bin/bash -ex
# Simple script for build and packaging of couchbase-data-api artifacts.

function usage() {
    echo
    echo "$0 -v <version> -b <build-number>"
    echo "   [-p <product>] [-g <go version]"
    echo "where:"
    echo "  -p: product; default to couchbase-data-api"
    echo "  -v: version number; eg. 0.1"
    echo "  -b: build number"
    echo "  -g: go version; defaults to 1.17"
    echo
}

#defaults
PRODUCT=couchbase-data-api
GO_REL=1.17

while getopts "b:g:p:v:h?" opt; do
    case $opt in
        b) BLD_NUM=$OPTARG;;
        g) GO_REL=$OPTARG;;
        p) PRODUCT=$OPTARG;;
        v) VERSION=$OPTARG;;
        h|?) usage
           exit 0;;
        *) echo "Invalid argument $opt"
           usage
           exit 1;;
    esac
done

if [ "x${VERSION}" = "x" ]; then
    echo "Version number not set"
    usage
    exit 2
fi

if [ "x${BLD_NUM}" = "x" ]; then
    echo "Build number not set"
    usage
    exit 2
fi

ARCH=$(uname -m)
CBDEPS_DIR=${HOME}/cbdeps

if [[ ${ARCH} == "arm64" ]]; then
    curl --fail -L https://packages.couchbase.com/cbdep/cbdep-linux-aarch64 -o cbdep
else
    curl --fail -L https://packages.couchbase.com/cbdep/cbdep-linux-${ARCH} -o cbdep
fi
chmod +x cbdep

mkdir -p ${CBDEPS_DIR}
./cbdep install golang ${GO_REL} -d ${CBDEPS_DIR}
export GOROOT=${CBDEPS_DIR}/go${GO_REL}
export PATH=${GOROOT}/bin:$PATH
cd ${WORKSPACE}/data-api
make build-rest-server

#Only need to package the binary
tar -czf ${PRODUCT}_${VERSION}-${BLD_NUM}-linux.${ARCH}.tar.gz rest-server
