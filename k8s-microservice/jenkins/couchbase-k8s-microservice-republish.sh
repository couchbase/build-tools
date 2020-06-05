#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/util/utils.sh

chk_set PRODUCT
chk_set PUBLIC_TAG
chk_set LATEST

# Compute next build number
${script_dir}/util/compute-next-rhcc-build.sh -p ${PRODUCT} -v ${PUBLIC_TAG}
source nextbuild.properties

# Rebuild the images locally - this will update the base image
${script_dir}/util/build-k8s-images.sh ${PRODUCT} ${PUBLIC_TAG} "" ${NEXT_BLD}

# Publish them again
${script_dir}/util/publish-k8s-images.sh \
    ${PRODUCT} ${PUBLIC_TAG} ${PUBLIC_TAG} ${NEXT_BLD} ${LATEST}
