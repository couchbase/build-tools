#!/bin/bash -ex

# This script is passed a PRODUCT, an INTERNAL_TAG, a PUBLIC_TAG, an
# OPENSHIFT_BUILD number, and a true/false value LATEST.
# It presumes that the following images are available:
#    build-docker.couchbase.com/cb-vanilla/${short_product}:${INTERNAL_TAG}
#    build-docker.couchbase.com/cb-rhcc/${short_product}:${INTERNAL_TAG}
# where short_product is PRODUCT with the leading "couchbase-" removed.
# Those images will be copied from the source registry to their destinations
#  on Docker Hub and RHCC -
# for RHCC it will append the OPENSHIFT_BUILD number to the public tag.
# If LATEST=true it will also update the :latest tag in Docker Hub (for Red
# Hat that has to be done via RHCC UI).

PRODUCT=$1
INTERNAL_TAG=$2
PUBLIC_TAG=$3
OPENSHIFT_BUILD=$4
LATEST=$5

internal_repo=build-docker.couchbase.com

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../../utilities/shell-utils.sh
source ${script_dir}/funclib.sh

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

publish() {
    org=$1
    external_image=$2

    internal_image=${internal_repo}/${org}/${short_product}:${INTERNAL_TAG}

    images=(${external_image})
    if [ "${org}" = "cb-vanilla" ]; then
        images+=(${external_image}-dockerhub)
        if [ "${LATEST}" = "true" ]; then
            images+=(${vanilla_registry}/couchbase/${short_product}:latest)
        fi
    fi
    for image in ${images[@]}; do
        echo @@@@@@@@@@@@@
        echo Copying ${internal_image} to ${image}...
        echo @@@@@@@@@@@@@
        skopeo copy --authfile /home/couchbase/.docker/config.json --all \
            docker://${internal_image} docker://${image}
    done
}

################ VANILLA

publish cb-vanilla \
    ${vanilla_registry}/couchbase/${short_product}:${PUBLIC_TAG}


################## RHCC

# There is no RHEL build for some products
if product_in_rhcc "${PRODUCT}"; then
    # This bit of code is shared with files in the redhat-openshift repository
    conf_dir=/home/couchbase/openshift/${PRODUCT}
    project_id=$(cat ${conf_dir}/project_id)
    # Need to login for production (Red Hat) registry
    set +x
    docker login -u unused-login -p "$(cat ${conf_dir}/registry_key)" scan.connect.redhat.com
    set -x

    publish cb-rhcc \
        ${rhcc_registry}/${project_id}/unused-image:${PUBLIC_TAG}-${OPENSHIFT_BUILD}
fi
