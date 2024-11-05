#!/bin/bash -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

usage() {
    set +x
    echo "Usage: $0 -p PRODUCT -t INTERNAL_TAG -r RELEASE_TAG_BASE -b REBUILD_NUM -c RHCC_CONFILE_FILE [-l] [-B] [-f]"
    echo
    echo "Handles the complete release-to-RHCC process - pulls the staged image"
    echo "(presumed to exist on the internal Docker registry with the correct"
    echo "name for PRODUCT and the specified internal tag), uploads it to quay.io"
    echo "with the specified release tag(s), runs preflight, and submits the"
    echo "preflight certification report to RHCC."
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
    echo "  <RELEASE_TAG_BASE>-<REBUILD_NUM>"
    echo "  <RELEASE_TAG_BASE>"
    echo "  <RELEASE_TAG_BASE>-rhcc"
    echo
    echo "  -B: build preflight from source"
    echo "  -l: also update :latest tag on RHCC"
    echo "  -f: force - skip some safety checks when uploading image (may be necessary"
    echo "      when retrying upload after preflight failure)"
    exit 1
}

LATEST="false"
BUILD_PREFLIGHT="false"
SAFETY_CHECKS="true"
while getopts :i:p:t:r:b:c:lBfh opt; do
    case ${opt} in
        p) PRODUCT="$OPTARG"
           ;;
        t) INTERNAL_TAG="$OPTARG"
           ;;
        r) RELEASE_TAG_BASE="$OPTARG"
           ;;
        c) CONFFILE="$OPTARG"
           ;;
        b) REBUILD_NUM="$OPTARG"
           ;;
        l) LATEST="true"
           ;;
        B) BUILD_PREFLIGHT="true"
           ;;
        f) SAFETY_CHECKS="false"
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
    local internal_image=$1
    local external_image=$2

    status "Uploading ${internal_image} to ${external_image}..."
    skopeo copy \
        --multi-arch all \
        --override-os linux \
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
    PREFLIGHTVER=1.10.2
    GOVER=1.22.5

    # The pre-compiled preflight binaries sometimes requires a newer
    # glibc than is available where this script runs. So we build it
    # ourselves. This also allows us to do our patch.
    mkdir -p ${WORKSPACE}/build
    pushd ${WORKSPACE}/build &> /dev/null
    cbdep install -d deps golang ${GOVER}
    export PATH=$(pwd)/deps/go${GOVER}/bin:${PATH}
    status Cloning openshift-preflight repository
    git clone https://github.com/redhat-openshift-ecosystem/openshift-preflight -b ${PREFLIGHTVER}
    cd openshift-preflight
    perl -pi -e 's/if user == ""/if user == "nobody"/' internal/policy/container/runs_as_nonroot.go
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

chk_set CONFFILE
chk_set PRODUCT
chk_set INTERNAL_TAG
chk_set REBUILD_NUM
chk_set RELEASE_TAG_BASE

# Read useful details from config json
product_path=".products.\"${PRODUCT}\""
image_basename=$(jq -r "${product_path}.image_basename" "${CONFFILE}")
project_id=$(jq -r "${product_path}.project_id" "${CONFFILE}")

# Derived value required for upload_image()
internal_image=build-docker.couchbase.com/cb-rhcc/${image_basename}:${INTERNAL_TAG}

# Additional private details from config json
stop_xtrace
registry_key=$(jq -r "${product_path}.registry_key" "${CONFFILE}")
api_key=$(jq -r ".rhcc.api_key" "${CONFFILE}")

# Set additional env vars so preflight can run
export PFLT_CERTIFICATION_PROJECT_ID=${project_id}
export PFLT_PYXIS_API_TOKEN=${api_key}

# Log in to quay.io, storing the result to a custom config so only RHCC
# credentials are in there (since preflight sends the entire Docker
# configuration to Red Hat including all credentials). Use
# REGISTRY_AUTH_FILE env var so that future skopeo commands will also
# make use of it.
status "Logging in to quay.io"
export REGISTRY_AUTH_FILE=$(pwd)/docker-auth.json
skopeo login \
    -u redhat-isv-containers+${project_id}-robot -p ${registry_key} \
    quay.io

# Also remember this docker auth file for preflight
export PFLT_DOCKERCONFIG=${REGISTRY_AUTH_FILE}
restore_xtrace

# See README.md for exhaustive details about why things are checked /
# uploaded / preflighted in this order.

# Determine the tag and SHA for this image.
image_base=quay.io/redhat-isv-containers/${project_id}
new_image_tag=${RELEASE_TAG_BASE}-${REBUILD_NUM}
new_image_sha=$(skopeo inspect docker://${internal_image} | jq -r '.Digest')

# Some safety checks. These can be skipped with -f.
if "${SAFETY_CHECKS}"; then
    # First ensure that the "new" tag doesn't already exist on RHCC.
    if [ -n "$(skopeo list-tags docker://${image_base} | jq --arg TAG ${new_image_tag} '.Tags[] | select(. == $TAG)' )" ]; then
        error "ERROR: ${image_base}:${new_image_tag} already exists!!"
    fi

    # Now ensure that the "new" image we're uploading doesn't already exist
    # on RHCC.
    if image_exists ${image_base}@${new_image_sha}; then
        error "ERROR: ${image_base}@${new_image_sha} already exists!!"
    fi
fi

# Now it should be safe to upload the new image to the new tag
upload_image ${internal_image} ${image_base}:${new_image_tag}

# Preflight the uploaded image so it is published
echo
status "Running preflight on container ${image_base}:${new_image_tag}..."
"${PREFLIGHT_EXE}" check container --submit ${image_base}:${new_image_tag}

# Wait for auto-publish to succeed
echo
status Waiting for auto-publish...
final_image=registry.connect.redhat.com/couchbase/${image_basename}:${new_image_tag}
for i in {200..0}; do
    # Temporarily unset REGISTRY_AUTH_FILE since it doesn't have the creds
    # for registry.connect.redhat.com
    if REGISTRY_AUTH_FILE= image_exists ${final_image}; then
        status "Auto-publish succeeded!"
        break
    fi
    if [ "${i}" == "0" ]; then
        error "Auto-publish timed out!"
    fi
    status "Still waiting ($i)..."
    sleep 3
done

# Finally, upload the (possibly-existing) :VERSION and :VERSION-rhcc tags.
# This should, at a minimum, cause `docker pull` to work for those tags.
echo
status "Uploading remaining images"
for tag in ${RELEASE_TAG_BASE} ${RELEASE_TAG_BASE}-rhcc; do
    upload_image ${internal_image} ${image_base}:${tag}

done
