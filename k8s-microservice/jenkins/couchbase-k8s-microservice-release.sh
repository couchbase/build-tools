#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/util/utils.sh

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

################### ARTIFACTS

# Upload artifacts to S3

release_dir=/releases/${PRODUCT}/${public_tag}
mkdir -p ${release_dir}
cd ${release_dir}
for file in /latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}/*${BLD_NUM}*; do
    if [[ $file =~ .*source.tar.gz ]]; then
        echo Skipping source file $file
        continue
    fi
    filename=$(basename ${file/${VERSION}-${BLD_NUM}/${public_tag}})
    cp -av ${file} ${filename}
    sha256sum ${filename} > ${filename}.sha256
    s3cmd -c ~/.ssh/live.s3cfg put -P ${filename} ${filename}.sha256 \
        s3://packages.couchbase.com/kubernetes/${public_tag}/
done