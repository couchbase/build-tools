#!/bin/bash -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

usage() {
    echo "Usage: $0 -i IMAGE"
    echo "       $0  -s -p PRODUCT -t INTERNAL_TAG -r RELEASE_TAG [ -r RELEASE TAG ... ] -c RHCC_CONFILE_FILE [-b]"
    echo
    echo "With only -i, simply runs 'preflight' on the specified image."
    echo "With -s and the other arguments, handles the complete release-to-RHCC"
    echo "process - pulls the staged image (presumed to exist on the internal"
    echo "Docker registry with the correct name for PRODUCT and the specified"
    echo "internal tag), uploads it to quay.io with the specified release tag(s),"
    echo "runs preflight, and submits the preflight certification report to"
    echo "RHCC. In this mode, -i is ignored."
    echo "  -b: build preflight from source"
    exit 1
}

SUBMIT="false"
BUILD_PREFLIGHT="false"
while getopts :i:p:t:r:c:sbh opt; do
    case ${opt} in
        i) IMAGE="$OPTARG"
           ;;
        p) PRODUCT="$OPTARG"
           ;;
        t) INTERNAL_TAG="$OPTARG"
           ;;
        r) RELEASE_TAGS="$RELEASE_TAGS $OPTARG"
           ;;
        c) CONFFILE="$OPTARG"
           ;;
        s) SUBMIT="true"
           ;;
        b) BUILD_PREFLIGHT="true"
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
    status "Uploading ${2} to ${3}..."
    skopeo copy \
        --override-arch ${1} \
        --override-os linux \
        --src-authfile ${HOME}/.docker/config.json \
        --dest-authfile ${PFLT_DOCKERCONFIG} \
        docker://${2} docker://${3}
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
    PREFLIGHTVER=1.2.1

    # The pre-compiled preflight binaries sometimes requires a newer
    # glibc than is available where this script runs. So we build it
    # ourselves. This also allows us to do our patch.
    mkdir -p ${WORKSPACE}/build
    pushd ${WORKSPACE}/build
    cbdep install -d deps golang 1.18.7
    export PATH=$(pwd)/deps/go1.18.7/bin:${PATH}
    git clone https://github.com/redhat-openshift-ecosystem/openshift-preflight -b ${PREFLIGHTVER}
    cd openshift-preflight
    perl -pi -e 's/if user == ""/if user == "nobody"/' certification/internal/policy/container/runs_as_nonroot.go
    make RELEASE_TAG=${PREFLIGHTVER} build
    cp -a preflight "${PREFLIGHT_EXE}"
    popd
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
    chk_set RELEASE_TAGS

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
    set +x
    status "Logging in to quay.io"
    docker --config $(pwd)/dockerconfig login \
        -u redhat-isv-containers+${project_id}-robot -p ${registry_key} quay.io

    # Set env vars so preflight can run
    export PFLT_CERTIFICATION_PROJECT_ID=${project_id}
    export PFLT_DOCKERCONFIG=$(pwd)/dockerconfig/config.json
    export PFLT_PYXIS_API_TOKEN=${api_key}
    export EXTRA_PREFLIGHT_ARGS=-s

    # Upload all images - we have to do this first because preflight -s
    # only works on an image already uploaded to quay.io.
    for tag in ${RELEASE_TAGS}; do
        image_base=quay.io/redhat-isv-containers/${project_id}:${tag}

        # If the image in the registry has an arm64 version, this will return
        # "arm64". Otherwise it will return some other arch.
        armarch=$(skopeo --override-arch arm64 --override-os linux \
            inspect --format '{{ .Architecture }}' \
            docker://${INTERNAL_IMAGE})
        if [ "${armarch}" = "arm64" ]; then
            arches="amd64 arm64"
        else
            arches="amd64"
        fi

        for arch in ${arches}; do
            if [ "${arch}" = "amd64" ]; then
                # Upload amd64 images with generic, non arch specific tags
                upload_image ${arch} ${INTERNAL_IMAGE} ${image_base}
                # Pick an amd64 tag to run preflight against
                [ -z "${EXTERNAL_IMAGE}" ] && EXTERNAL_IMAGE=${image_base}
            else
                # Pick an arm64 tag to run preflight against
                [ -z "${EXTERNAL_ARM_IMAGE}" ] && EXTERNAL_ARM_IMAGE=${image_base}-${arch}
            fi
            # Upload arch specific tags for all architectures
            upload_image ${arch} ${INTERNAL_IMAGE} ${image_base}-${arch}
        done
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
status ::::::::::::: RUNNING PREFLIGHT :::::::::::::::::::
"${PREFLIGHT_EXE}" check container ${EXTERNAL_IMAGE} ${EXTRA_PREFLIGHT_ARGS}

# If we pushed arm tags, run preflight against that image too
if [ ! -z "${EXTERNAL_ARM_IMAGE}" ]; then
    status ::::::::::::: RUNNING ARM PREFLIGHT :::::::::::::::::::
    "${PREFLIGHT_EXE}" check container ${EXTERNAL_ARM_IMAGE} ${EXTRA_PREFLIGHT_ARGS}
fi
