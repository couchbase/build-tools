#!/bin/bash -ex

# This script is passed a PRODUCT, an INTERNAL_TAG, a PUBLIC_TAG, an
# OPENSHIFT_BUILD number, and a true/false value LATEST.
#
# It presumes that the following images are available:
#    build-docker.couchbase.com/cb-vanilla/${short_product}:${INTERNAL_TAG}
#    build-docker.couchbase.com/cb-rhcc/${short_product}:${INTERNAL_TAG}
# where short_product is PRODUCT with the leading "couchbase-" removed.
#
# Those images will be copied from the source registry to their destinations
# on Docker Hub and RHCC - for RHCC it will also append the OPENSHIFT_BUILD
# number to the public tag. If OPENSHIFT_BUILD is omitted or '0', this script
# will skip the upload to RHCC.
#
# On both Docker Hub and RHCC it will also create the redundant -dockerhub
# and -rhcc tags.
#
# If LATEST=true it will also update the :latest tag.

usage() {
    echo "Usage: $(basename $0) -p PRODUCT -i INTERNAL_TAG -t PUBLIC_TAG -o OPENSHIFT_BUILD [ -l ]"
    echo "Options:"
    echo "   -l - Also create :latest tag"
    exit 1
}

LATEST=false
OPENSHIFT_BUILD=0
while getopts ":p:i:t:o:l" opt; do
    case ${opt} in
        p)
            PRODUCT=${OPTARG}
            ;;
        i)
            INTERNAL_TAG=${OPTARG}
            ;;
        t)
            PUBLIC_TAG=${OPTARG}
            ;;
        o)
            OPENSHIFT_BUILD=${OPTARG}
            ;;
        l)
            LATEST=true
            ;;
        \?)
            usage
            ;;
        :)
            echo "-${OPTARG} requires an argument"
            usage
            ;;
    esac
done

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))
build_tools_dir=$(cd "${script_dir}" && git rev-parse --show-toplevel)
source ${build_tools_dir}/utilities/shell-utils.sh
source ${script_dir}/funclib.sh

chk_set PRODUCT
chk_set INTERNAL_TAG
chk_set PUBLIC_TAG
chk_set LATEST

internal_repo=build-docker.couchbase.com
short_product=${PRODUCT/couchbase-/}

vanilla_registry=index.docker.io
rhcc_registry=registry.connect.redhat.com

# Uncomment when doing local testing
#vanilla_registry=build-docker.couchbase.com

#
# Publish to public registries, including redundant tags
#

################ VANILLA

status Publishing to Docker Hub...
internal_image=${internal_repo}/cb-vanilla/${short_product}:${INTERNAL_TAG}
internal_key=$(image_key ${internal_image})
external_base=${vanilla_registry}/couchbase/${short_product}
images=(${external_base}:${PUBLIC_TAG} ${external_base}:${PUBLIC_TAG}-dockerhub)
if ${LATEST}; then
    images+=(${external_base}:latest)
fi
for image in ${images[@]}; do
    header Publishing ${internal_image} to ${image}
    status Checking current Docker Hub image key...
    image_key=$(image_key ${image})
    if [ "$(image_key ${internal_image})" = "$(image_key ${image})" ]; then
        status "Keys match, skipping copy!"
    else
        status "Keys don't match, performing copy"
        skopeo copy --authfile ${HOME}/.docker/config.json \
            --all --preserve-digests \
            docker://${internal_image} docker://${image}
    fi
done

################## RHCC

# There is no RHEL build for some products
if product_in_rhcc "${PRODUCT}" && [ "${OPENSHIFT_BUILD}" != "0" ]; then

    internal_image=${internal_repo}/cb-rhcc/${short_product}:${INTERNAL_TAG}
    external_base=${rhcc_registry}/couchbase/${short_product}:${PUBLIC_TAG}

    header Publishing ${internal_image} to ${external_base}...

    # RHCC doesn't support publishing multi-arch images, so we check and
    # publish each arch individually
    for arch in amd64 arm64; do

        # Give more meaningful message if particular arch doesn't even exist
        internal_key=$(image_${arch}_key ${internal_image})
        if [ -z "${internal_key}" ]; then
            echo "${internal_image} has no ${arch} component, skipping publish"
            continue
        fi

        status Checking current RHCC ${arch} image key...
        if [ "${arch}" = "arm64" ]; then
            external_key=$(image_arm64_key ${external_base}-arm64)
        else
            external_key=$(image_amd64_key ${external_base})
        fi
        if [ "${internal_key}" = "${external_key}" ]; then
            status "Keys match, skipping copy!"
            continue
        fi

        status "Keys don't match, performing copy"
        if ${LATEST}; then
            LATEST_ARG="-r latest"
        fi

        # Important to push the unique X.Y.Z-B version first, as that's the
        # one that rhcc-certify-and-publish.sh will attempt to preflight
        # check. When republishing, preflight will fail if asked to verify
        # an already-published tag.
        ${build_tools_dir}/rhcc/scripts/rhcc-certify-and-publish.sh -s -b \
            -c ${HOME}/.docker/rhcc-metadata.json \
            -p ${PRODUCT} -t ${INTERNAL_TAG} -a ${arch} \
            -r ${PUBLIC_TAG}-${OPENSHIFT_BUILD} -r ${PUBLIC_TAG}  \
            -r ${PUBLIC_TAG}-rhcc ${LATEST_ARG}
    done
fi
