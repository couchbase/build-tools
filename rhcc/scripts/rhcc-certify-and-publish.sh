#!/bin/bash -ex

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

usage() {
    echo "Usage: $0 -i IMAGE"
    echo "   or: $0 -s -p PRODUCT -t INTERNAL_TAG -a <amd64|arm64> -r RELEASE_TAG_BASE -b REBUILD_NUM -c RHCC_CONFILE_FILE [-l] [-B]"
    echo
    echo "With only -i, simply runs 'preflight' on the specified image."
    echo
    echo "With -s and the other arguments, handles the complete release-to-RHCC"
    echo "process - pulls the staged image (presumed to exist on the internal"
    echo "Docker registry with the correct name for PRODUCT and the specified"
    echo "internal tag), uploads it to quay.io with the specified release tag(s),"
    echo "runs preflight, and submits the preflight certification report to"
    echo "RHCC. In this mode, -i is ignored."
    echo
    echo "INTERNAL_TAG must exactly match a tag on build-docker.couchbase.com/cb-rhcc."
    echo
    echo "RELEASE_TAG_BASE will generally be the version number, but could also"
    echo "be eg. '7.6.0-MP1'."
    echo "REBUILD_NUM must be unique for every time a given RELEASE_TAG_BASE is"
    echo "published to RHCC, generally starting from 1 when the GA image is uploaded."
    echo
    echo "This script will create the following tags on RHCC:"
    echo
    echo "  <RELEASE_TAG_BASE>-<ARCH>"
    echo "  <RELEASE_TAG_BASE>-<REBUILD_NUM>-<ARCH>"
    echo "  <RELEASE_TAG_BASE>-rhcc-<ARCH>"
    echo
    echo "When ARCH is 'amd64', it will also create each of the above tags without"
    echo "the -<ARCH> suffix."
    echo
    echo "  -B: build preflight from source"
    echo "  -l: also update :latest tag on RHCC"
    exit 1
}

SUBMIT="false"
LATEST="false"
BUILD_PREFLIGHT="false"
while getopts :i:p:t:a:r:b:c:slBh opt; do
    case ${opt} in
        i) IMAGE="$OPTARG"
           ;;
        p) PRODUCT="$OPTARG"
           ;;
        t) INTERNAL_TAG="$OPTARG"
           ;;
        a) ARCH="$OPTARG"
           ;;
        r) RELEASE_TAG_BASE="$OPTARG"
           ;;
        c) CONFFILE="$OPTARG"
           ;;
        b) REBUILD_NUM="$OPTARG"
           ;;
        s) SUBMIT="true"
           ;;
        l) LATEST="true"
           ;;
        B) BUILD_PREFLIGHT="true"
           ;;
        h) usage
           ;;
        \?) # Unrecognized option, show help
            echo -e \\n"Invalid option: ${OPTARG}" 1>&2
            usage
    esac
done

chk_cmd curl jq

if [ -z "${WORKSPACE}" ]; then
    export WORKSPACE=$(pwd)
fi

mkdir -p ${WORKSPACE}/workdir
cd ${WORKSPACE}/workdir

function upload_image {
    arch=$1
    internal_image=$2
    external_image=$3
    status "Uploading ${internal_image} to ${external_image}..."
    skopeo copy \
        --override-arch ${arch} \
        --override-os linux \
        --src-authfile ${HOME}/.docker/config.json \
        --dest-authfile ${PFLT_DOCKERCONFIG} \
        docker://${internal_image} docker://${external_image}
}

# preflight makes this 'artifacts' directory to store various logs, but
# apparently not until after it tries to create PFLT_LOGFILE as you'll
# get an error if the directory doesn't already exist.
export PFLT_LOGFILE=./artifacts/preflight.log
rm -rf artifacts
mkdir artifacts

# Download/build preflight
PREFLIGHT_EXE="$(pwd)/preflight"
if [ -x "${PREFLIGHT_EXE}" ]; then
    status "Using existing preflight binary"
elif ${BUILD_PREFLIGHT}; then
    status "Building preflight..."
    PREFLIGHTVER=1.9.1

    # The pre-compiled preflight binaries sometimes requires a newer
    # glibc than is available where this script runs. So we build it
    # ourselves. This also allows us to do our patch.
    mkdir -p ${WORKSPACE}/build
    pushd ${WORKSPACE}/build &> /dev/null
    cbdep install -d deps golang 1.19.7
    export PATH=$(pwd)/deps/go1.19.7/bin:${PATH}
    status Cloning openshift-preflight repository
    git clone https://github.com/redhat-openshift-ecosystem/openshift-preflight -b ${PREFLIGHTVER}
    cd openshift-preflight
    perl -pi -e 's/if user == ""/if user == "nobody"/' certification/internal/policy/container/runs_as_nonroot.go
    status Building preflight binary
    make RELEASE_TAG=${PREFLIGHTVER} build
    cp -a preflight "${PREFLIGHT_EXE}"
    popd &> /dev/null
else
    status "Downloading preflight..."
    LATEST_URL=$(curl --silent --write-out '%{redirect_url}' \
        https://github.com/redhat-openshift-ecosystem/openshift-preflight/releases/latest)
    # Convert URL to downloadable binary
    DL_URL="${LATEST_URL/tag/download}/preflight-linux-amd64"
    curl -Lo "${PREFLIGHT_EXE}" "${DL_URL}"
    chmod 755 "${PREFLIGHT_EXE}"
fi

# Set everything up in the environment appropriately for preflight_image(),
# including uploading image(s) if we're submitting
if ${SUBMIT}; then
    # If this is a real submit operation, look up appropriate product metadata
    # and log in to RHCC.
    chk_set CONFFILE
    chk_set PRODUCT
    chk_set INTERNAL_TAG
    chk_set REBUILD_NUM
    chk_set ARCH
    chk_set RELEASE_TAG_BASE

    # Read useful details from config json
    product_path=".products.\"${PRODUCT}\""
    image_basename=$(jq -r "${product_path}.image_basename" "${CONFFILE}")
    project_id=$(jq -r "${product_path}.project_id" "${CONFFILE}")

    # Additional details from config json that are only for this function
    registry_key=$(jq -r "${product_path}.registry_key" "${CONFFILE}")
    api_key=$(jq -r ".rhcc.api_key" "${CONFFILE}")

    # Derived value required for upload_image()
    INTERNAL_IMAGE=build-docker.couchbase.com/cb-rhcc/${image_basename}:${INTERNAL_TAG}

    # Log in to quay.io, using custom config directory so only the RHCC
    # credentials are in there (since the entire Docker configuration gets
    # sent to Red Hat including all credentials).
    stop_xtrace
    status "Logging in to quay.io"
    docker --config $(pwd)/dockerconfig login \
        -u redhat-isv-containers+${project_id}-robot -p ${registry_key} \
        quay.io
    restore_xtrace

    # Set env vars so preflight can run
    export PFLT_CERTIFICATION_PROJECT_ID=${project_id}
    export PFLT_DOCKERCONFIG=$(pwd)/dockerconfig/config.json
    export PFLT_PYXIS_API_TOKEN=${api_key}
    export EXTRA_PREFLIGHT_ARGS=-s

    # Upload all images - we have to do this first because preflight -s
    # only works on an image already uploaded to quay.io.
    for tag in ${RELEASE_TAG_BASE}-${REBUILD_NUM} ${RELEASE_TAG_BASE} ${RELEASE_TAG_BASE}-rhcc; do
        image_base=quay.io/redhat-isv-containers/${project_id}:${tag}

        # Upload arch specific tags for all architectures
        upload_image ${ARCH} ${INTERNAL_IMAGE} ${image_base}-${ARCH}

        # Remember the first uploaded tag for running preflight.
        [ -z "${EXTERNAL_IMAGE}" ] && EXTERNAL_IMAGE=${image_base}-${ARCH}

        # Also upload amd64 images with generic, non arch specific tags
        if [ "${ARCH}" = "amd64" ]; then
            upload_image ${ARCH} ${INTERNAL_IMAGE} ${image_base}
        fi
    done

else
    # Just scanning some random image
    chk_set IMAGE

    EXTERNAL_IMAGE=${IMAGE}

    # Seems like we need to set this to scan images outside scan.connect.redhat.com
    export PFLT_DOCKERCONFIG=${HOME}/.docker/config.json
fi

# Run preflight on a specific remote image. Expects various PFLT_*
# environment variables to have been set appropriately.
echo
status Running preflight on container ${EXTERNAL_IMAGE}...
"${PREFLIGHT_EXE}" check container ${EXTERNAL_IMAGE} ${EXTRA_PREFLIGHT_ARGS}
