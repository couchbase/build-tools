#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/util/utils.sh

chk_set PRODUCT

cd ${PRODUCT}
make dist
