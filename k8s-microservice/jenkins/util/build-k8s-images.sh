#!/bin/bash -ex

# This script is passed the three standard build coordinates (omitting
# RELEASE), plus a fourth argument, OPENSHIFT_BUILD. The third coordinate,
# BLD_NUM, is optional; if it is an empty string, this is presumed to be a
# re-build of an existing GA version. The script will download the
# -image.tgz artifact for the build (either from latestbuilds if BLD_NUM is
# specified, or else the internal release mirror if not); unpack it; and
# build all Docker images contained within it, according to the algorithm
# here:
# https://hub.internal.couchbase.com/confluence/display/CR/Grand+Unified+Build+and+Release+Process+for+Operator
#
# It will tag the resulting images with fake orgs:
#     cb-vanilla/${short_product}:${tag}
#     cb-rhcc/${short_product}:${tag}
# where short_product is PRODUCT with the leading "couchbase-" removed, and
# tag is either VERSION-BLD_NUM or just VERSION if BLD_NUM is empty.
#
# It is up to the calling code to re-tag those images depending on where they
# are to be published and what they are to be named, and then remove all
# cb-* images when then are done.

shopt -s extglob

PRODUCT=$1
VERSION=$2
BLD_NUM=$3
OPENSHIFT_BUILD=$4

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../../utilities/shell-utils.sh
source ${script_dir}/funclib.sh

chk_set PRODUCT
chk_set VERSION
chk_set OPENSHIFT_BUILD
# BLD_NUM should also be set, but may be an empty string

heading() {
    echo
    echo @@@@@@@@@@@@@@@@@
    echo $1
    echo @@@@@@@@@@@@@@@@@
}

# Ensure 'images' directory exists but is empty
rm -rf images
mkdir images
cd images

if [ -z "${BLD_NUM}" ]; then
    tag=${VERSION}
    base_url=http://releases.service.couchbase.com/builds/releases/${PRODUCT}/${VERSION}
else
    tag=${VERSION}-${BLD_NUM}
    base_url=http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}
fi
filename=${PRODUCT}-image_${tag}.tgz
url=${base_url}/${filename}

heading "Downloading ${url}..."
curl --fail -LO ${url}
heading "Extracting ${filename}..."
tar xzf ${filename}
rm ${filename}

if [ -e Dockerfile ]; then
    # Content is in root directory; move into subdir named for PRODUCT
    mkdir ${PRODUCT}
    mv !(${PRODUCT}) ${PRODUCT}
fi

for local_product in *; do
    pushd ${local_product}

    short_product=${local_product/couchbase-/}
    heading "Building Vanilla image for ${short_product}:${tag}..."
    DOCKER_BUILDKIT=1 docker build --pull -f Dockerfile \
        -t cb-vanilla/${short_product}:${tag} \
        --build-arg PROD_VERSION=${VERSION} \
        .

    # Some projects don't do RHCC
    if product_in_rhcc "${PRODUCT}"; then
        heading "Building RHCC image for ${short_product}..."
        DOCKER_BUILDKIT=1 docker build --pull -f Dockerfile.rhel \
            -t cb-rhcc/${short_product}:${tag} \
            --build-arg PROD_VERSION=${VERSION} \
            --build-arg PROD_BUILD=${BLD_NUM} \
            --build-arg OS_BUILD=${OPENSHIFT_BUILD} \
            .
    fi
    popd
done

heading "Done building images for ${PRODUCT} ${VERSION} ${BLD_NUM}"
