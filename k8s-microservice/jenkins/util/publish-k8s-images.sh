#!/bin/bash -e

# This script is passed a PRODUCT, an INTERNAL_TAG, a PUBLIC_TAG, an
# OPENSHIFT_BUILD number, a true/false value LATEST, and an optional REGISTRY.
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
# The REGISTRY argument can be used to limit which registry to publish to:
# 'dockerhub', 'rhcc', or 'all' (default) if omitted.
#
# On both Docker Hub and RHCC it will also create the redundant -dockerhub
# and -rhcc tags.
#
# If LATEST=true it will also update the :latest tag.

usage() {
    echo "Usage: $(basename $0) -p PRODUCT -i INTERNAL_TAG -t PUBLIC_TAG -o OPENSHIFT_BUILD [ -l ] [ -r REGISTRY ]"
    echo "Options:"
    echo "   -l - Also create :latest tag"
    echo "   -r - Specify the registry to use - dockerhub, rhcc, or all (default)"
    exit 1
}

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))
source ${script_dir}/../../../utilities/shell-utils.sh

LATEST=false
OPENSHIFT_BUILD=0
REGISTRY="all"
while getopts ":p:i:t:o:r:l" opt; do
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
        r)
            REGISTRY=${OPTARG}
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

publishing_redhat() {
    if [ "${REGISTRY}" = "rhcc" -o "${REGISTRY}" = "all" -a "${OPENSHIFT_BUILD}" != "0" ]; then
        return 0
    fi
    return 1
}

publishing_vanilla() {
    if [ "${REGISTRY}" = "dockerhub" -o "${REGISTRY}" = "all" ]; then
        return 0
    fi
    return 1
}

if publishing_redhat; then
    chk_set OPENSHIFT_BUILD
fi

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

if publishing_vanilla; then
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
fi

################## RHCC

if publishing_redhat; then
    internal_image=${internal_repo}/cb-rhcc/${short_product}:${INTERNAL_TAG}
    external_base=${rhcc_registry}/couchbase/${short_product}:${PUBLIC_TAG}

    header Publishing ${internal_image} to ${external_base}...

    status Checking current RHCC ${arch} image key...
    internal_key=$(image_key ${internal_image})
    external_key=$(image_key ${external_base})
    if [ "${internal_key}" = "${external_key}" ]; then
        status "Keys match, skipping publish!"
    else
        status "Keys don't match, performing publish"
        if ${LATEST}; then
            LATEST_ARG="-l"
        fi
        ${build_tools_dir}/rhcc/scripts/rhcc-certify-and-publish.sh \
            -c ${HOME}/.docker/rhcc-metadata.json \
            -p ${PRODUCT} -t ${INTERNAL_TAG} \
            -r ${PUBLIC_TAG} -b ${OPENSHIFT_BUILD} ${LATEST_ARG}
    fi
fi
