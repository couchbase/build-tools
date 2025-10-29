#!/bin/bash -ex

# Builds and pushes pre-GA and post-GA Docker images for a variety of
# products.
# ----------------------------
#
# This script always builds multi-architecture images (linux/amd64 and
# linux/arm64).
#
# This script is passed the standard build coordinates PRODUCT and
# VERSION - it is assumed that this will only be run for products where
# RELEASE==VERSION.
#
# It is used in two different scenarios:
#
#  1. To create normal, pre-GA images as part of the standard build
#     process (called from couchbase-k8s-microservice-docker.sh). In
#     this case, the build coordinate BLD_NUM must be passed.
#  2. To re-publish post-GA images, for example to update the base
#     image. In this case, BLD_NUM is not passed, and the -P (publish)
#     argument is passed instead. The images will be built and then
#     immediately published to the public registries.
#
# The actions taken are mostly the same in each case; differences will
# be noted below.
#
# The script will download the -image.tgz artifact for the build; unpack
# it; and build all Docker images contained within it, according to the
# algorithm here:
# https://hub.internal.couchbase.com/confluence/display/CR/Grand+Unified+Build+and+Release+Process+for+Operator
#
# The -image.tgz artifact is downloaded from latestbuilds for a normal
# pre-GA build, or from the internal release mirror for a post-GA
# republish.
#
# Images will be built and pushed to our internal registry with fake
# orgs cb-vanilla and cb-rhcc, i.e:
#
#     build-docker.couchbase.com/cb-vanilla/${short_product}:${tag}
#     build-docker.couchbase.com/cb-rhcc/${short_product}:${tag}
#
# where short_product is PRODUCT with the leading "couchbase-" removed,
# and tag is either VERSION-BLD_NUM (pre-GA build) or just VERSION
# (post-GA republish). Some products aren't intended to be available via
# RHCC and so they will not be pushed to cb-rhcc.
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
# A REGISTRY parameter can be specified to limit which registry types to
# push to. If set to "dockerhub", only vanilla images will be built and
# pushed. If set to "rhcc", only RHCC images will be built and pushed.
# If omitted or set to "all", both types of images will be built and
# pushed.

shopt -s extglob

usage() {
    echo "Usage: $(basename $0) -p PRODUCT -v VERSION [ -b BLD_NUM  | -P ] [ -R REGISTRY ]"
    echo "Options:"
    echo "  -P - Immediately Publish each product's images after building (will publish with just :VERSION tags)"
    echo "  -l - Also create :latest tags in each repository"
    echo "  -R - Specify the registry to use (dockerhub, rhcc, or all [default])"
    exit 1
}

PUBLISH=false
REGISTRY="all"
while getopts ":p:v:b:R:lP" opt; do
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

if [ "${PUBLISH}" = "false" -a -z "${BLD_NUM}" ]; then
    echo "When not publishing (-P), BLD_NUM must be specified"
    usage
fi
if [ "${PUBLISH}" = "true" -a -n "${BLD_NUM}" ]; then
    echo "When publishing (-P), BLD_NUM must NOT be specified"
    usage
fi

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
    local os_build=$5

    internal_registry=build-docker.couchbase.com

    if [ "${org}" = "cb-vanilla" ]; then
        dockerfile=Dockerfile
    else
        dockerfile=Dockerfile.rhel
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

    header "Building ${org} image for ${short_product}:${tag}..."

    docker buildx build \
        --platform "linux/amd64,linux/arm64" \
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
    tag=${VERSION}
    base_url=http://releases.service.couchbase.com/builds/releases/${PRODUCT}/${VERSION}
else
    tag=${VERSION}-${BLD_NUM}
    base_url=http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}
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
            ${external_registry}
    fi

    # Some projects don't do RHCC
    if building_redhat && product_in_rhcc "${PRODUCT}"; then

        # Need to determine OPENSHIFT_BUILD. This is always "1" for a
        # pre-GA build. For a post-GA rebuild, compute it from the RHCC
        # registry.
        if $PUBLISH; then
            OPENSHIFT_BUILD=$(${script_dir}/../../../rhcc/scripts/compute-next-rhcc-build.sh -p ${local_product} -v ${VERSION})
        else
            OPENSHIFT_BUILD=1
        fi
        build-image cb-rhcc ${short_product} ${tag} \
            ${external_registry} ${OPENSHIFT_BUILD}
    fi

    popd &> /dev/null

    # If requested, go on and publish this product's images.
    if ${PUBLISH}; then
        PUBLISH_CMD="${script_dir}/publish-k8s-images.sh -p ${local_product} -i ${tag} -t ${VERSION} -r ${REGISTRY}"
        if [ -n "${OPENSHIFT_BUILD}" ]; then
            PUBLISH_CMD+=" -o ${OPENSHIFT_BUILD}"
        fi
        ${PUBLISH_CMD}
    fi
done

header "Done building images for ${PRODUCT} ${VERSION} ${BLD_NUM}"
