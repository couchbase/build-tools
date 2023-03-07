#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

GOVERSION=$(gover_from_manifest)

TOOLDIR=$(mktemp -d -q --tmpdir=$(pwd) toolsXXXXX)

if [ ! -z "${GOVERSION}" ]; then
    # Create temp directory in WORKSPACE to install golang
    cbdep install -d ${TOOLDIR} golang ${GOVERSION}
    export PATH=${TOOLDIR}/go${GOVERSION}/bin:${PATH}
fi

for dep in protoc; do
    ver=$(depver_from_manifest ${dep})
    if [ ! -z "${ver}" ]; then
        cbdep install -d ${TOOLDIR} ${dep} ${ver}
        export PATH=${TOOLDIR}/${dep}-${ver}/bin:${PATH}
    fi
done

cd ${PRODUCT}
# Also pass GOVERSION to Make, since some projects expect to find it there
make GO_VERSION=${GOVERSION} dist
