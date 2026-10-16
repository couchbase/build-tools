#!/bin/bash -ex

# Dumps an existing multi-arch k8s-microservice image from the private
# pre-GA registry to a multi-arch OCI archive tarball, and
# optionally uploads it to S3. Based on rhcc/scripts/create-one-off-rhcc.sh.
#
# The source image is the one build-k8s-images.sh pushed for a build:
#
#     ghcr.io/cb-rhcc/${short_product}:${VERSION}-${BLD_NUM}     (-r rhcc)
#     ghcr.io/cb-vanilla/${short_product}:${VERSION}-${BLD_NUM}  (-r dockerhub)
#
# where short_product is PRODUCT with the leading "couchbase-" removed.
# All of the image's architectures are kept in the one tarball, which is
# named after the image's public name, so "docker load" (with the
# containerd image store) or "podman load" gives e.g.
# registry.connect.redhat.com/couchbase/converge-redis:0.9.0. It writes
# e.g. couchbase-converge-redis_0.9.0-linux-rhcc.tar (plus a .sha256) in
# the current directory.

usage() {
    echo "Usage: $(basename $0) -p PRODUCT -v VERSION -b BLD_NUM -r rhcc|dockerhub [ -x SUFFIX ] [ -P ]"
    echo "Options:"
    echo "  -r - Which image to dump: rhcc (ghcr.io/cb-rhcc) or dockerhub (ghcr.io/cb-vanilla)"
    echo "  -x - Suffix for the public tag, e.g. -x beta gives VERSION-beta"
    echo "  -P - Upload the tarball to s3://packages.couchbase.com/releases/PRODUCT/PUBLIC_TAG"
    exit 1
}

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

PUBLISH_TO_S3=false
while getopts ":p:v:b:r:x:Ph" opt; do
    case ${opt} in
        p) PRODUCT=${OPTARG};;
        v) VERSION=${OPTARG};;
        b) BLD_NUM=${OPTARG};;
        r) REGISTRY=${OPTARG};;
        x) SUFFIX=${OPTARG};;
        P) PUBLISH_TO_S3=true;;
        h) usage;;
        \?) echo "Invalid option -${OPTARG}"
            usage;;
        :) echo "-${OPTARG} requires an argument"
           usage;;
    esac
done

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM
chk_set REGISTRY

case "${REGISTRY}" in
    rhcc)
        internal_registry=ghcr.io/cb-rhcc
        public_base=registry.connect.redhat.com/couchbase
        ;;
    dockerhub)
        internal_registry=ghcr.io/cb-vanilla
        public_base=docker.io/couchbase
        ;;
    *)
        echo "-r must be rhcc or dockerhub, not '${REGISTRY}'"
        usage
        ;;
esac

if [ -z "${SUFFIX}" ]; then
    PUBLIC_TAG=${VERSION}
else
    PUBLIC_TAG=${VERSION}-${SUFFIX}
fi

short_product=${PRODUCT/couchbase-/}
IMAGE="${internal_registry}/${short_product}:${VERSION}-${BLD_NUM}"
public_image="${public_base}/${short_product}:${PUBLIC_TAG}"
filename="${PRODUCT}_${PUBLIC_TAG}-linux-${REGISTRY}.tar"

# The ghcr.io orgs are private; use the same Docker credentials as
# publish-k8s-images.sh
if [ -f "${HOME}/.docker/config.json" ]; then
    AUTH_ARG="--src-authfile ${HOME}/.docker/config.json"
fi

header "Dumping ${IMAGE} (all architectures) to ${filename}"
rm -f ${filename} ${filename}.sha256
skopeo copy --all ${AUTH_ARG} \
    docker://${IMAGE} \
    oci-archive:$(pwd)/${filename}:${public_image}
sha256sum ${filename} | cut -c -64 > ${filename}.sha256

if ${PUBLISH_TO_S3}; then
    S3_PATH=s3://packages.couchbase.com/releases/${PRODUCT}/${PUBLIC_TAG}
    for file in ${filename} ${filename}.sha256; do
        aws s3 cp ${file} ${S3_PATH}/${file} --acl public-read
    done
fi
