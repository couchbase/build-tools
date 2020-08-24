#!/bin/bash -ex

# This script is passed a PRODUCT, an INTERNAL_TAG, a PUBLIC_TAG, an
# OPENSHIFT_BUILD number, and a true/false value LATEST.
# It presumes that the following images are available
# locally:
#    cb-vanilla/${short_product}:${INTERNAL_TAG}
#    cb-rhcc/${short_product}:${INTERNAL_TAG}
# where short_product is PRODUCT with the leading "couchbase-" removed.
# If those images aren't available locally, they will be pulled from
# the build-docker.couchbase.com registry.
# It will retag those images with the appropriate external registry
# names and the public tag and push them to Docker Hub and RHCC -
# for RHCC it will append the OPENSHIFT_BUILD number to the public tag.
# If LATEST=true it will also update the :latest tag in Docker Hub (for Red
# Hat that has to be done via RHCC UI).
# It will also clean up all images locally after publishing.

PRODUCT=$1
INTERNAL_TAG=$2
PUBLIC_TAG=$3
OPENSHIFT_BUILD=$4
LATEST=$5

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set INTERNAL_TAG
chk_set PUBLIC_TAG
chk_set OPENSHIFT_BUILD
chk_set LATEST

short_product=${PRODUCT/couchbase-/}

vanilla_registry=index.docker.io
rhcc_registry=scan.connect.redhat.com

# Uncomment when doing local testing
#vanilla_registry=build-docker.couchbase.com
#rhcc_registry=build-docker.couchbase.com

tag_and_publish() {
    org=$1
    external_image=$2

    internal_image=${org}/${short_product}:${INTERNAL_TAG}

    # See if we need to pull the internal image
    docker inspect --format ' ' ${internal_image} || {
        registry_image=build-docker.couchbase.com/${internal_image}
        docker pull ${registry_image}
        docker tag ${registry_image} ${internal_image}
        docker rmi ${registry_image}
    }

    echo @@@@@@@@@@@@@
    echo Pushing ${external_image} image...
    echo @@@@@@@@@@@@@
    docker tag ${internal_image} ${external_image}
    docker push ${external_image}
    docker rmi ${external_image}

    if [ x$LATEST = xtrue ]; then
        external_latest_image=${vanilla_registry}/couchbase/${short_product}:latest
        echo @@@@@@@@@@@@@
        echo Updating ${external_latest_image}...
        echo @@@@@@@@@@@@@
        docker tag ${internal_image} ${external_latest_image}
        docker push ${external_latest_image}
        docker rmi ${external_latest_image}
    fi

    docker rmi ${internal_image}
}

################ VANILLA

tag_and_publish cb-vanilla \
    ${vanilla_registry}/couchbase/${short_product}:${PUBLIC_TAG}


################## RHCC

# This bit of code is shared with files in the redhat-openshift repository
conf_dir=/home/couchbase/openshift/${PRODUCT}
project_id=$(cat ${conf_dir}/project_id)
# Need to login for production (Red Hat) registry
set +x
docker login -u unused-login -p "$(cat ${conf_dir}/registry_key)" scan.connect.redhat.com
set -x

# Never push :latest tag to RHCC
LATEST=false

tag_and_publish cb-rhcc \
    ${rhcc_registry}/${project_id}/unused-image:${PUBLIC_TAG}-${OPENSHIFT_BUILD}
