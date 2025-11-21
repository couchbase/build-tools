#!/bin/bash -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

usage() {
    set +x
    echo "Usage: $0 -p PRODUCT -t INTERNAL_TAG -r RELEASE_TAG_BASE -b REBUILD_NUM -c RHCC_CONFILE_FILE [-l]"
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
    echo "  -l: also update :latest tag on RHCC"
    exit 1
}

LATEST="false"
while getopts :i:p:t:r:b:c:lh opt; do
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

# The image name on our internal registry
internal_image=build-docker.couchbase.com/cb-rhcc/${image_basename}:${INTERNAL_TAG}

# Additional private details from config json
stop_xtrace

registry_key=$(jq -r "${product_path}.registry_key" "${CONFFILE}")
api_key=$(jq -r ".rhcc.api_key" "${CONFFILE}")

# Set additional env vars so preflight can run
export PFLT_CERTIFICATION_COMPONENT_ID=${project_id}
export PFLT_PYXIS_API_TOKEN=${api_key}

# Log in to quay.io, storing the result to a custom config so only RHCC
# credentials are in there (since preflight sends the entire Docker
# configuration to Red Hat including all credentials).
status "Logging in to quay.io"
export PFLT_DOCKERCONFIG=$(pwd)/docker-auth.json
skopeo login \
    --authfile ${PFLT_DOCKERCONFIG} \
    -u redhat-isv-containers+${project_id}-robot -p ${registry_key} \
    quay.io

# Also have to separately log in using `docker login`. Docker doesn't
# allow using a credentials file, other than by specifying DOCKER_CONFIG
# which overrides the entire config directory, which includes all buildx
# setup :(
docker login -u redhat-isv-containers+${project_id}-robot -p ${registry_key} quay.io

restore_xtrace

# Image names
quay_image=quay.io/redhat-isv-containers/${project_id}
final_image=registry.connect.redhat.com/couchbase/${image_basename}

# Create a one-off Dockerfile for the image with an extraneous top
# layer, to ensure that every single thing we push to RHCC is different
# from every single thing we've ever pushed to RHCC before.
cat > Dockerfile <<EOF
FROM ${internal_image}
ARG CACHEBUST
EOF

# Pick a random number for CACHEBUST so that we can build something
# different than anything before, but the same different thing each
# time.
CACHEBUST=${RANDOM}

# END PREP STEPS


# Upload a new image (build it first, if necessary) to quay.io with the
# specified tag(s).
function upload_to_quay() {
    local -n tags="$1"
    declare -g CACHEBUST quay_image

    local TAG_ARGS=""
    for tag in "${tags[@]}"; do
        TAG_ARGS+=" -t ${quay_image}:${tag}"
    done
    status "Creating and uploading new image ${quay_image} with tags (${tags[@]})..."
    docker buildx build --pull --push \
        --build-arg CACHEBUST=${CACHEBUST} \
        --provenance=false \
        --platform linux/amd64,linux/arm64\
        ${TAG_ARGS} .
}

# Wait for the final image to become pullable on RHCC with the specified
# tag(s).
function wait_for_pullable() {
    local -n tags="$1"
    declare -g final_image image_digest

    for tag in "${tags[@]}"; do
        for arch in amd64 arm64; do
            status "Waiting for auto-publish of ${final_image}:${tag} (${arch})..."
            for i in {200..0}; do
                digest=$(skopeo inspect --override-arch ${arch} --override-os linux \
                    docker://${final_image}:${tag} \
                    --format '{{.Digest}}' 2>/dev/null || echo "not yet")
                if [ "${digest}" == "not yet" ]; then
                    if [ "${i}" == "0" ]; then
                        error "Auto-publish timed out!"
                    fi
                    status "Still waiting ($i)..."
                    sleep 3
                    continue
                elif [ "${digest}" == "${image_digest}" ]; then
                    status "Auto-publish of ${final_image}:${tag} (${arch}) succeeded!"
                    break
                else
                    error "Auto-publish of ${final_image}:${tag} (${arch}) has wrong digest '${digest}'!"
                fi
            done
        done
    done
}

# See README.md for exhaustive details about why things everything from
# here on out is utterly stupid.

# First, create real new image with all-new tag, based on REBUILD_NUM
TAGS=("${RELEASE_TAG_BASE}-${REBUILD_NUM}")
upload_to_quay TAGS
image_digest=$(docker buildx imagetools inspect ${quay_image}:${TAGS[0]} | grep Digest | awk '{print $2}')
status "Uploaded image digest: ${image_digest}"

# Next, run preflight on that image. If this succeeds, auto-publish will
# kick in and the new tag will become pullable.
status "Running preflight on container ${quay_image}:${TAGS[0]}..."
"${PREFLIGHT_EXE}" check container --submit ${quay_image}:${TAGS[0]}

# Ensure this new unique tag is now pullable on RHCC
wait_for_pullable TAGS

# Now, create the other tags we want, based on the same image. These
# tags will be associated with the already-pullable image, which makes
# them also pullable (although it rarely is correctly reflected in the
# Partner Connect UI or the public catalog).
TAGS=("${RELEASE_TAG_BASE}-${REBUILD_NUM}" "${RELEASE_TAG_BASE}" "${RELEASE_TAG_BASE}-rhcc")
if $LATEST; then
    TAGS+=("latest")
fi
upload_to_quay TAGS
wait_for_pullable TAGS


docker logout quay.io

header All done!
