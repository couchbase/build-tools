#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

GOVERSION=$(gover_from_manifest)

if [ ! -z "${GOVERSION}" ]; then
    # Create temp directory in WORKSPACE to install golang
    GODIR=$(mktemp -d -q --tmpdir=$(pwd) golangXXXXX)
    cbdep install -d ${GODIR} golang ${GOVERSION}
    export PATH=${GODIR}/go${GOVERSION}/bin:${PATH}
fi

cd ${PRODUCT}
# Also pass GOVERSION to Make, since some projects expect to find it there
make GO_VERSION=${GOVERSION} dist
