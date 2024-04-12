#!/bin/bash -ex

function usage() {
    echo
    echo "$0 -r <product>  -r <release> -v <version> -b <build-number>"
    echo "where:"
    echo "  -p: product name: sync_gateway, couchbase-lite-ios"
    echo "  -r: release branch: master, 1.5.0, etc."
    echo "  -v: version number: 1.5.0, 2.0DB15, etc."
    echo "  -b: build number: 128, etc."
    echo "  -s: version suffix, eg. 'MP1' or 'beta' [optional]"
    echo "  -l: Push it to live (production) s3. Default is to push to staging [optional]"
    echo "  -c: how to handle community builds [optional]:"
    echo "        public: publicly accessible [default]"
    echo "        private: uploaded but not downloadable"
    echo "        none: do NOT upload to s3"
    echo
}

COMMUNITY=public
LIVE=false

while getopts "p:r:v:b:s:c:hl" opt; do
    case $opt in
        p) PRODUCT=$OPTARG;;
        r) RELEASE=$OPTARG;;
        v) VERSION=$OPTARG;;
        b) BLD_NUM=$OPTARG;;
        s) SUFFIX=$OPTARG;;
        c) COMMUNITY=$OPTARG;;
        l) LIVE=true;;
        h|?) usage
           exit 0;;
        *) echo "Invalid argument $opt"
           usage
           exit 1;;
    esac
done

if [ "x${PRODUCT}" = "x" ]; then
    echo "Product name not set"
    usage
    exit 2
fi

if [ "x${RELEASE}" = "x" ]; then
    echo "Release product name not set"
    usage
    exit 2
fi

if [ "x${VERSION}" = "x" ]; then
    echo "Version number not set"
    usage
    exit 2
fi

if [ "x${BLD_NUM}" = "x" ]; then
    echo "Build number not set"
    usage
    exit 2
fi

LB_MOUNT=/latestbuilds
if [ ! -e ${LB_MOUNT} ]; then
    echo "'latestbuilds' directory is not mounted"
    exit 3
fi

RELEASES_MOUNT=/releases
if [ ! -e ${REL_MOUNT} ]; then
    echo "'releases' directory is not mounted"
    exit 3
fi

# Compute target filename components
if [ -z "${SUFFIX}" ]; then
    RELEASE_DIRNAME=$VERSION
    FILENAME_VER=$VERSION
else
    RELEASE_DIRNAME=$VERSION-$SUFFIX
    FILENAME_VER=$VERSION-$SUFFIX
fi

# Primary latestbuilds build output directory
BUILD_DIR=${LB_MOUNT}/${PRODUCT}/${RELEASE}/${BLD_NUM}

# Compute root destination directories, creating them as necessary.
if [[ "${LIVE}" = "true" ]]; then
    S3_ROOT=s3://packages.couchbase.com/releases
    RELEASE_ROOT=${RELEASES_MOUNT}
else
    S3_ROOT=s3://packages-staging.couchbase.com/releases
    RELEASE_ROOT=${RELEASES_MOUNT}/staging
    mkdir -p -m 755 ${RELEASE_ROOT}
fi

# Determine product specific directories
case "${PRODUCT}" in
    sync_gateway)
        S3_DIR=${S3_ROOT}/couchbase-sync-gateway/${RELEASE_DIRNAME}
        RELEASE_DIR=${RELEASE_ROOT}/mobile/couchbase-sync-gateway/${RELEASE_DIRNAME}
        mkdir -p -m 755 ${RELEASE_DIR}
        SRC_DIR=${BUILD_DIR}
        ;;
    couchbase-lite-android*|couchbase-lite-c|couchbase-lite-ios|couchbase-lite-java*|couchbase-lite-vector-search|couchbase-lite-cblite|couchbase-lite-log)
        S3_DIR=${S3_ROOT}/${PRODUCT}/${RELEASE_DIRNAME}
        RELEASE_DIR=${RELEASE_ROOT}/mobile/${PRODUCT}/${RELEASE_DIRNAME}
        mkdir -p -m 755 ${RELEASE_DIR}
        SRC_DIR=${BUILD_DIR}
        ;;
    couchbase-lite-net*)
        S3_DIR=${S3_ROOT}/${PRODUCT}/${RELEASE_DIRNAME}
        RELEASE_DIR=${RELEASE_ROOT}/mobile/${PRODUCT}/${RELEASE_DIRNAME}
        mkdir -p -m 755 ${RELEASE_DIR}
        SRC_DIR=${BUILD_DIR}/release
        ;;
    *)
        echo "Unsupported Product!"
        usage
        exit 1
        ;;
esac

upload()
{
    echo "Uploading ${RELEASE_DIRNAME} to ${S3_DIR} ..."
    echo

    # Upload EE first
    aws s3 sync ${UPLOAD_TMP_DIR} ${S3_DIR}/ --acl public-read --exclude "*" --include "*enterprise*" --include "*Enterprise*" --include "*ee*" --exclude "CBLTestServer*" --exclude "test-reports*" --exclude "analysis-reports*" --exclude "testserver*"

    # Upload CE files
    case ${COMMUNITY} in
        "private") ACL="private";;
        "none") ACL="";;  #don't need to set ACL since we are not going to upload CE files
        *) ACL="public-read";;
    esac

    if [[ ! -z $ACL ]]; then
        echo "Community builds are uploaded in $ACL mode ..."
        aws s3 sync ${UPLOAD_TMP_DIR} ${S3_DIR}/ --acl $ACL --exclude "*enterprise*" --exclude "*Enterprise*" --exclude "*ee*" --exclude "CBLTestServer*" --exclude "test-reports*" --exclude "analysis-reports*" --exclude "testserver*"
    else
        echo "Community builds are not uploaded..."
    fi

    # Archive internal releases
    echo "Archiving ${UPLOAD_TMP_DIR} to ${RELEASE_DIR} ..."
    echo
    mkdir -p ${RELEASE_DIR}
    rsync -au ${UPLOAD_TMP_DIR}/* ${RELEASE_DIR}/
}

cd ${SRC_DIR}
FILES=$(ls -Iblackduck -Iunfinished | egrep -v 'source|\.xml|\.json|\.properties|\.md5|\.sha|coverage|CHANGELOG|changes\.log|unsigned|logtest|litetest|Package.swift')
UPLOAD_TMP_DIR=/tmp/${RELEASE}-${BLD_NUM}
rm -rf ${UPLOAD_TMP_DIR} && mkdir -p ${UPLOAD_TMP_DIR}
cd ${UPLOAD_TMP_DIR}
for fl in $FILES; do
    target_file=${fl/${RELEASE}-${BLD_NUM}/${FILENAME_VER}}
    echo "Copying ${SRC_DIR}/${fl} to $target_file ..."
    cp ${SRC_DIR}/${fl} ${target_file}
    echo "Generating sha256 on $target_file ..."
    sha256sum ${target_file} > ${target_file}.sha256
done

# Copy manifest and notices.txt to release directory. These files are
# *technically* named ${PRODUCT}-${VERSION}-${BLD_NUM}, unlike the other
# build artifats; however this script uses VERSION to mean something
# slightly different, which doesn't match the filenames. Fortunately for
# all mobile products, RELEASE==VERSION, so we can safely use ${RELEASE}
# in these filenames as well.
# These files always live in the primary BUILD_DIR.
cp ${BUILD_DIR}/${PRODUCT}-${RELEASE}-${BLD_NUM}-manifest.xml ${PRODUCT}-${RELEASE}-manifest.xml
NOTICES_FILE=${BUILD_DIR}/blackduck/${PRODUCT}-${RELEASE}-${BLD_NUM}-notices.txt
if [ -f ${NOTICES_FILE} ]; then
    cp ${NOTICES_FILE} ${PRODUCT}-${VERSION}-notices.txt
fi

echo "Uploading files from ${UPLOAD_TMP_DIR} ..."
upload
rm -rf ${UPLOAD_TMP_DIR}
