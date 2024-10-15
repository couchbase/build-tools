#!/bin/bash -ex

# quick-and-dirty script to dump an existing multi-arch Docker image to
# two tarballs, and optionally upload to S3
# Only works for couchbase/server currently

usage() {
    echo "Usage: $0 -v VERSION -b BLD_NUM -x SUFFIX -P"
    exit 1
}

PUBLISH_TO_S3=false
while getopts "v:b:x:Ph?" opt; do
    case $opt in
        v) VERSION=$OPTARG;;
        b) BLD_NUM=$OPTARG;;
        x) SUFFIX=$OPTARG;;
        P) PUBLISH_TO_S3=true;;
        h|?) usage;;
        *) echo "Invalid argument $opt"
           usage;;
    esac
done

if [ -z "$VERSION" ] || [ -z "$BLD_NUM" ] ; then
    usage
fi

if [ -z "$SUFFIX" ]; then
    PUBLIC_TAG=${VERSION}
else
    PUBLIC_TAG=${VERSION}-${SUFFIX}
fi

IMAGE="build-docker.couchbase.com/cb-rhcc/server:${VERSION}-${BLD_NUM}"

for arch in amd64 arm64; do
    public_image="registry.connect.redhat.com/couchbase/server:${PUBLIC_TAG}-${arch}"
    filename="couchbase-server-enterprise_${PUBLIC_TAG}-linux_${arch}-rhcc.tar"
    rm -f ${filename}
    skopeo --override-arch $arch copy \
        docker://${IMAGE} \
        docker-archive:$(pwd)/${filename}:${public_image}
    sha256sum ${filename} | cut -c -64 > ${filename}.sha256
done

if ${PUBLISH_TO_S3}; then
    S3_PATH=s3://packages.couchbase.com/releases/${PUBLIC_TAG}
    for file in *rhcc.tar*; do
        aws s3 cp ${file} ${S3_PATH}/${file} --acl public-read
    done
fi
