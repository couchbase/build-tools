#!/bin/bash -e

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh

chk_set PRODUCT
chk_set VERSION
chk_set REGISTRY

function republish() {
    product=$1
    version=$2

    short_product=${product/couchbase-/}

    if [ "${REGISTRY}" = "dockerhub" ]; then
        vanilla_args="-d linux/amd64,linux/arm64"
    elif [ "${REGISTRY}" = "rhcc" ]; then
        # Figure out if we need to do RHCC, and if so, what arches
        NEXT_BLD=0
        if product_in_rhcc "${PRODUCT}"; then
                NEXT_BLD=$(${script_dir}/../../rhcc/scripts/compute-next-rhcc-build.sh \
                    -p ${product} -v ${version})
                rhcc_args="-o ${NEXT_BLD} -r linux/amd64,linux/arm64"
        fi
    fi

    # Rebuild the images on internal registry - this will update the base image.
    # Pass the -P argument to have the new images Published.
    status Rebuilding ${product} ${version}
    ${script_dir}/util/build-k8s-images.sh -R ${REGISTRY} -P -p ${product} -v ${version} ${vanilla_args} ${rhcc_args}
}


# Main program logic begins here

ROOT=$(pwd)

# See if this version is marked to be ignored - some older
# versions just won't build anymore due to changes in package
# repositories, etc.
if curl --silent --fail \
    http://releases.service.couchbase.com/builds/releases/${PRODUCT}/${VERSION}/.norebuild
then
    status "Skipping ${PRODUCT} ${VERSION} due to .norebuild"
    exit 0
fi

republish ${PRODUCT} ${VERSION}
