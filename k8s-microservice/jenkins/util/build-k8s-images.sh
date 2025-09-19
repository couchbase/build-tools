#!/bin/bash -ex

# Builds and pushes pre-GA Docker images for a variety of products.
#
# This script is passed the three standard build coordinates (omitting
# RELEASE - it is assumed that this will only be run for products where
# RELEASE==VERSION), plus a fourth argument, OPENSHIFT_BUILD. The third
# coordinate, BLD_NUM, is optional; if it is an empty string, this is
# presumed to be a re-build of an existing GA version. The script will
# download the -image.tgz artifact for the build (either from
# latestbuilds if BLD_NUM is specified, or else the internal release
# mirror if not); unpack it; and build all Docker images contained
# within it, according to the algorithm here:
# https://hub.internal.couchbase.com/confluence/display/CR/Grand+Unified+Build+and+Release+Process+for+Operator
#
# Images will be built and pushed to our internal registry with fake
# orgs cb-vanilla and cb-rhcc, i.e:
#
#     build-docker.couchbase.com/cb-vanilla/${short_product}:${tag}
#     build-docker.couchbase.com/cb-rhcc/${short_product}:${tag}
#
# where short_product is PRODUCT with the leading "couchbase-" removed,
# and tag is either VERSION-BLD_NUM or just VERSION if BLD_NUM is empty.
# Some products aren't intended to be available via RHCC and so they
# will not be pushed to cb-rhcc.
#
# Images will also be pushed to external private registries, depending
# on the product. For most products, the images will have identical
# names as the build-docker ones except on ghcr.io, ie:
#
#     ghcr.io/cb-vanilla/${short_product}:${tag}
#     ghcr.io/cb-rhcc/${short_product}:${tag}
#
# Some products instead have their pre-GA images on an AWS ECR registry.
# ECR URLs don't have an "organization" component, just the registry
# name and repository name, so those images will look something like
#
#     284614897128.dkr.ecr.us-east-2.amazonaws.com/${short_product}:${tag}
#
# None of those products have RHCC equivalents, so only the above image
# will be pushed.
#
# A REGISTRY parameter can be specified to limit which registry types to push
# to. If set to "dockerhub", only vanilla images will be built and pushed.
# If set to "rhcc", only RHCC images will be built and pushed.
# If omitted or set to "all", both types of images will be built and pushed.
#
# NOTE: If BLD_NUM is empty, then VANILLA_ARCHES and/or RHCC_ARCHES must be
# specified so this script can rebuild the right images in preparation
# for republishing them. Either or both of these may be the string
# "none", in which case the corresponding architecture will be silently
# skipped.

shopt -s extglob

usage() {
    echo "Usage: $(basename $0) -p PRODUCT -v VERSION [ -b BLD_NUM | (-d VANILLA_ARCHES | -r RHCC_ARCHES | both) ] [ -o OPENSHIFT_BUILD ] [ -R REGISTRY ] [ -P ]"
    echo "Options:"
    echo "  -P - Immediately Publish each product's images after building (will publish with just :VERSION tags)"
    echo "  -l - Also create :latest tags in each repository"
    echo "  -R - Specify the registry to use (dockerhub, rhcc, or all [default])"
    echo "  -o - OPENSHIFT_BUILD (optional, will be generated if not provided when building RHCC images)"
    exit 1
}

PUBLISH=false
REGISTRY="all"
while getopts ":p:v:b:o:d:r:R:lP" opt; do
    case ${opt} in
        p)
            PRODUCT=${OPTARG}
            ;;
        v)
            VERSION=${OPTARG}
            ;;
        b)
            BLD_NUM=${OPTARG}
            ;;
        o)
            OPENSHIFT_BUILD=${OPTARG}
            ;;
        d)
            VANILLA_ARCHES=${OPTARG}
            ;;
        r)
            RHCC_ARCHES=${OPTARG}
            ;;
        l)
            LATEST=true
            ;;
        P)
            PUBLISH=true
            ;;
        R)
            REGISTRY=${OPTARG}
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

building_redhat() {
    if [ "${REGISTRY}" = "rhcc" -o "${REGISTRY}" = "all" ]; then
        return 0
    fi
    return 1
}

building_vanilla() {
    if [ "${REGISTRY}" = "dockerhub" -o "${REGISTRY}" = "all" ]; then
        return 0
    fi
    return 1
}

build-image() {
    local org=$1
    local short_product=$2
    local tag=$3
    local external_registry=$4
    local arches=$5
    local os_build=$6

    internal_registry=build-docker.couchbase.com

    if [ "${org}" = "cb-vanilla" ]; then
        dockerfile=Dockerfile
    else
        dockerfile=Dockerfile.rhel
    fi

    # If no arches are specified, just return
    if [ "${arches}" = "none" ]; then
        return
    fi

    # Is the external_registry ECR?
    if [[ ${external_registry} =~ .*\.amazonaws\.com ]]; then
        # ECR doesn't have a concept of "org", so we drop that. Raise
        # error if we're asked to push an RHCC image to ECR as that
        # would result in using the same image name for both the
        # "cb-vanilla" and "cb-rhcc" images.
        if [ "${org}" = "cb-rhcc" ]; then
            echo "Cannot push RHCC images to ECR!"
            exit 5
        fi
        external_org=${external_registry}

        # Also need to do the ECR login dance. Note we are hard-coding
        # the region us-east-2 here.
        aws ecr get-login-password --region us-east-2 |\
            docker login --username AWS --password-stdin ${external_registry}
    else
        external_org=${external_registry}/${org}
    fi

    if [ "${org}" = "cb-rhcc" ]; then
        PROVENANCE_ARG="--provenance=false"
    fi

    # Are we doing :latest?
    if ${LATEST}; then
        tags="$tag latest"
    else
        tags="$tag"
    fi

    # Compute the full set of -t args
    TAG_ARG=""
    for t in ${tags}; do
        TAG_ARG+=" --tag ${internal_registry}/${org}/${short_product}:${t}"
        TAG_ARG+=" --tag ${external_org}/${short_product}:${t}"
    done

    header "Building ${arches} ${org} image for ${short_product}:${tag}..."

    docker buildx build \
        --platform "${arches}" \
        --ssh default --push --pull -f ${dockerfile} \
        --no-cache \
        ${TAG_ARG} \
        --build-arg PROD_VERSION=${VERSION} \
        --build-arg PROD_BUILD=${BLD_NUM} \
        --build-arg OS_BUILD=${os_build} \
        --build-arg GO_VERSION=${GOVERSION} \
        ${PROVENANCE_ARG} \
        .
}



# Main program logic begins here

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../../utilities/shell-utils.sh
source ${script_dir}/funclib.sh

# Validate arguments, including identifying whether this is a normal
# pre-GA build (ie, BLD_NUM is set) or a re-publish of a post-GA build
# (BLD_NUM is not set).
chk_set PRODUCT
chk_set VERSION

if [ -z "${BLD_NUM}" ]; then
    # When no BLD_NUM, we need at least one of VANILLA_ARCHES or RHCC_ARCHES
    # depending on which registry we're building for
    if building_vanilla; then
        chk_set VANILLA_ARCHES
    fi

    if building_redhat; then
        chk_set RHCC_ARCHES
    fi

    tag=${VERSION}
    base_url=http://releases.service.couchbase.com/builds/releases/${PRODUCT}/${VERSION}
else
    tag=${VERSION}-${BLD_NUM}
    base_url=http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}

    if building_vanilla && [ -z "${VANILLA_ARCHES}" ]; then
        VANILLA_ARCHES=$(product_platforms ${PRODUCT})
    fi

    if building_redhat && [ -z "${RHCC_ARCHES}" ]; then
        RHCC_ARCHES=$(product_platforms ${PRODUCT})
    fi
fi

# Download build manifest and image.tgz artifact
manifest_filename=${PRODUCT}-${tag}-manifest.xml
filename=${PRODUCT}-image_${tag}.tgz
url=${base_url}/${filename}

status "Downloading manifest ${manifest_filename} to compute GOVERSION"
curl --silent --show-error --fail -L -o manifest.xml ${base_url}/${manifest_filename}
GOVERSION=$(gover_from_manifest)

# Ensure 'images' directory exists but is empty
rm -rf images
mkdir images
cd images

status "Downloading ${url}..."
curl --silent --show-error --fail -LO ${url}
status "Extracting ${filename}..."
tar xzf ${filename}
rm ${filename}

if [ -e Dockerfile ]; then
    # Content is in root directory; move into subdir named for PRODUCT
    mkdir ${PRODUCT}
    mv !(${PRODUCT}) ${PRODUCT}
fi

eval `ssh-agent` &> /dev/null
if [ -e ~/.ssh/ns-buildbot.rsa ]; then
    ssh-add ~/.ssh/ns-buildbot.rsa &> /dev/null
fi

external_registry=$(product_external_registry ${PRODUCT})
for local_product in *; do
    pushd ${local_product} &> /dev/null
    short_product=${local_product/couchbase-/}

    if building_vanilla; then
        build-image cb-vanilla ${short_product} ${tag} \
            ${external_registry} ${VANILLA_ARCHES}
    fi

    # Some projects don't do RHCC
    if building_redhat && product_in_rhcc "${PRODUCT}"; then
        NEXT_BLD=$(${script_dir}/../../../rhcc/scripts/compute-next-rhcc-build.sh -p ${local_product} -v ${VERSION})
        build-image cb-rhcc ${short_product} ${tag} \
            ${external_registry} ${RHCC_ARCHES} ${NEXT_BLD}
    fi

    popd &> /dev/null

    # If requested, go on and publish this product's images.
    if ${PUBLISH}; then
        PUBLISH_CMD="${script_dir}/publish-k8s-images.sh -p ${local_product} -i ${tag} -t ${VERSION}"
        if [ -n "${OPENSHIFT_BUILD}" ]; then
            PUBLISH_CMD+=" -o ${OPENSHIFT_BUILD}"
        elif building_redhat; then
            PUBLISH_CMD+=" -o ${NEXT_BLD}"
        fi
        if [ "${REGISTRY}" != "all" ]; then
            PUBLISH_CMD+=" -r ${REGISTRY}"
        fi
        ${PUBLISH_CMD}
    fi
done

header "Done building images for ${PRODUCT} ${VERSION} ${BLD_NUM}"
