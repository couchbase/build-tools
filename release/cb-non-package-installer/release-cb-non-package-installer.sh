#!/bin/bash -ex

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

chk_set VERSION
chk_set BLD_NUM
chk_set LATEST

if [ ! -z "${SUFFIX}" ]; then
    VERSION_STRING="${VERSION}-${SUFFIX}"
else
    VERSION_STRING="${VERSION}"
fi

PROD_NAME=cb-non-package-installer
RELEASE_DIR_BASE=/releases
RELEASE_DIR=${RELEASE_DIR_BASE}/${PROD_NAME}/${VERSION_STRING}
mkdir -p ${RELEASE_DIR}
HTTPS_BASE=https://packages.couchbase.com/${PROD_NAME}
S3_ROOT=s3://packages.couchbase.com/${PROD_NAME}

cd /latestbuilds/python_tools/${PROD_NAME}/${VERSION}/${BLD_NUM}

UPLOADED_URLS=

copy_to_releases() {
    installer=$1
    # This should be file path relative to /releases
    # or https://packages.couchbase.com
    release_file=$2

    cp -a ${installer} ${RELEASE_DIR_BASE}/${release_file}
    UPLOADED_URLS="${HTTPS_BASE}/${release_file}\n${UPLOADED_URLS}"
    sha256sum ${RELEASE_DIR_BASE}/${release_file} \
        > ${RELEASE_DIR_BASE}/${release_file}.sha256
}

release_installer() {
    installer=$1
    # This should be directory path relative to /releases
    # or https://packages.couchbase.com
    out_dir=$2

    if [ "${ARCH}" = "x86_64" ]; then
        echo "Releasing x86_64 binary to non-arch path"
        copy_to_releases ${installer} ${out_dir}/${PROD_NAME}
    fi

    echo "Releasing ${ARCH} binary to arch-specific path"
    copy_to_releases ${installer} ${out_dir}/${PROD_NAME}-${ARCH}
}

# Build-specific files
cp -a *manifest* *properties* ${RELEASE_DIR}

# Installer binaries
for ARCH in x86_64 aarch64; do
    release_installer linux-${ARCH}/${PROD_NAME} ${PROD_NAME}/${VERSION_STRING}

    if [ "${LATEST}" == "true" ]; then
        echo
        echo 'Also updating version-less locations'
        echo
        release_installer linux-${ARCH}/${PROD_NAME} ${PROD_NAME}
    fi
done

# Update S3
aws s3 sync ${RELEASE_DIR_BASE}/${PROD_NAME}/ ${S3_ROOT}/ --acl public-read

set +x
echo ::::::::::::::::::
echo Uploaded files for ${PROD_NAME} ${VERSION_STRING}
echo ::::::::::::::::::
echo Installers:
printf "${UPLOADED_URLS}" | sort
echo SHAs:
printf "${UPLOADED_URLS}" | sort | sed -e 's/$/.sha256/'
echo ::::::::::::::::::
