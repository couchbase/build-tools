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

################### ARTIFACTS

# Upload artifacts to S3

upload_path=${PRODUCT}/${public_tag}
upload_url_base=packages.couchbase.com/${upload_path}
release_dir=/releases/${upload_path}
mkdir -p ${release_dir}
pushd ${release_dir}
shopt -s nullglob
UPLOADS=
for file in /latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}/*${BLD_NUM}*; do
    if [[ $file =~ .*source.tar.gz ]]; then
        echo Skipping source code file $file
        continue
    fi
    if [[ "${PRODUCT}" != "couchbase-operator" && $file =~ ${PRODUCT}-image.* ]]; then
        echo Skipping internal image file $file
        continue
    fi
    filename=$(basename ${file/${VERSION}-${BLD_NUM}/${public_tag}})
    cp -av ${file} ${filename}
    sha256sum ${filename} > ${filename}.sha256
    aws s3 cp ${filename} \
        s3://${upload_url_base}/${filename} --acl public-read
    aws s3 cp --content-type "text/plain" ${filename}.sha256 \
        s3://${upload_url_base}/${filename}.sha256 --acl public-read
    if [[ ! $file =~ .*manifest.* && ! $file =~ .*properties.* ]]; then
        UPLOADS=1
    fi
done

if [ "${UPLOADS}" = "1" ]; then
    ignorefiles="manifest|properties"
    links=$(aws s3 ls s3://${upload_url_base}/ | egrep -v "$ignorefiles" | awk -v s3dir=https://${upload_url_base}/ '{print s3dir $4}')
    rel=$(echo "$links" | grep -v ".sha256")
    rel_sha=$(echo "$links" | grep ".sha256")

    set +x
    echo :::::::::::::::::::::::::::::::
    echo UPLOADED URLS
    echo :::::::::::::::::::::::::::::::

    echo "Binaries:"
    echo
    echo "$rel"
    echo
    echo "Shas:"
    echo
    echo "$rel_sha"
    echo
    echo :::::::::::::::::::::::::::::::
    set -x
fi

popd

# Add git tag for release - this should take place after the S3 upload
# to ensure artifacts are available to any subsequent workflow
# execution
tag_release "${PRODUCT}" "${VERSION}" "${BLD_NUM}" "${public_tag}"
