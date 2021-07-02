#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh

chk_set PRODUCT
chk_set PUBLIC_TAG
chk_set LATEST

# Compute next build number
if [ product_in_rhcc "${PRODUCT}" ]; then
    ${script_dir}/util/compute-next-rhcc-build.sh -p ${PRODUCT} -v ${PUBLIC_TAG}
    source nextbuild.properties
else
    NEXT_BLD=9999 # dummy value - not used for this product
fi

# Rebuild the images locally - this will update the base image
${script_dir}/util/build-k8s-images.sh ${PRODUCT} ${PUBLIC_TAG} "" ${NEXT_BLD}

# Publish them again
${script_dir}/util/publish-k8s-images.sh \
    ${PRODUCT} ${PUBLIC_TAG} ${PUBLIC_TAG} ${NEXT_BLD} ${LATEST}
