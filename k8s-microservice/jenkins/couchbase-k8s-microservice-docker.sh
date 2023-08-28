#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

# Figure out if this is the highest version of the product; if so,
# also push :latest tag
highest_version=$(
    curl --silent http://dbapi.build.couchbase.com:8000/v1/products/${PRODUCT}/releases \
    | jq --raw-output '[ .[][] | select(contains("-")|not) ] | .[-1]'
)
if [[ ${highest_version} = ${VERSION} && "${VERSION}" != *"-"* ]]; then
    LATEST_ARG=-l
fi

# Build the images into the internal and external pre-GA registries.
OS_BUILD=${OS_BUILD-1}
${script_dir}/util/build-k8s-images.sh \
    -p ${PRODUCT} -v ${VERSION} -b ${BLD_NUM} -o ${OS_BUILD} ${LATEST_ARG}
