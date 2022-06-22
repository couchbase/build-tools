#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

# Extract Golang version to use from manifest
GOANNOTATION=$(xmllint \
    --xpath 'string(//project[@name="build"]/annotation[@name="GOVERSION"]/@value)' \
    manifest.xml)
GOVERSION=${GOANNOTATION:-1.13.3}

# Create temp directory in WORKSPACE to install golang
GODIR=$(mktemp -d -q --tmpdir=$(pwd) golangXXXXX)
cbdep install -d ${GODIR} golang ${GOVERSION}
export PATH=${GODIR}/go${GOVERSION}/bin:${PATH}

cd ${PRODUCT}
make dist
