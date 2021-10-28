#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM
chk_set LATEST

# If PUBLIC_TAG is non-empty in the environment, use that; otherwise
# default to VERSION. (Usually the public tag for a release is the same
# as the version number, but sometimes we'll do things like 1.2.0-beta.)
if [ -z "${PUBLIC_TAG}" ]; then
    public_tag=${VERSION}
else
    public_tag=${PUBLIC_TAG}
fi

# Publish images with this public tag, and a REBUILD number of 1.
${script_dir}/util/publish-k8s-images.sh ${PRODUCT} ${VERSION}-${BLD_NUM} ${public_tag} 1 ${LATEST}

case "${PRODUCT}" in
    couchbase-admission-controller|couchbase-operator-certification)
        echo "Only do docker stuff for ${PRODUCT}; all done!"
        exit 0
        ;;
esac

# Add git tag for release
tag_release "${PRODUCT}" "${public_tag}" "${BLD_NUM}"

################### ARTIFACTS

# Upload artifacts to S3

release_dir=/releases/${PRODUCT}/${public_tag}
mkdir -p ${release_dir}
cd ${release_dir}
shopt -s nullglob
for file in /latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}/*${BLD_NUM}*; do
    if [[ $file =~ .*source.tar.gz || $file =~ ${PRODUCT}-image.* ]]; then
        echo Skipping file $file
        continue
    fi
    filename=$(basename ${file/${VERSION}-${BLD_NUM}/${public_tag}})
    cp -av ${file} ${filename}
    sha256sum ${filename} > ${filename}.sha256
    aws s3 cp ${filename} \
      s3://packages.couchbase.com/${PRODUCT}/${public_tag}/${filename} --acl public-read
    aws s3 cp --content-type "text/plain" ${filename}.sha256 \
      s3://packages.couchbase.com/${PRODUCT}/${public_tag}/${filename}.sha256 --acl public-read
done
