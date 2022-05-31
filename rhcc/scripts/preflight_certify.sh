#!/bin/bash -e

# Downloads and runs Red Hat's "preflight" container certification
# tool. Optionally submits the results to RHCC for a to-be-published
# image.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

usage() {
    echo "Usage: $0 -i <image> [ -s -k <RH API key>  ]"
    echo "  When using -s (submit), <image> must be at scan.connect.redhat.com"
    exit 1
}

SUBMIT="false"
while getopts :i:k:sh opt; do
    case ${opt} in
        i) IMAGE="$OPTARG"
           ;;
        k) APIKEY="$OPTARG"
           ;;
        s) SUBMIT="true"
           ;;
        h) usage
           ;;
        \?) # Unrecognized option, show help
            echo -e \\n"Invalid option: ${OPTARG}" 1>&2
            show_help
    esac
done

chk_set IMAGE
if ${SUBMIT}; then
    chk_set APIKEY
fi

chk_cmd curl jq

# Get URL for latest release of preflight
if [ ! -x ./preflight ]; then
    echo "Downloading preflight..."
    LATEST_URL=$(curl --silent --write-out '%{redirect_url}' \
        https://github.com/redhat-openshift-ecosystem/openshift-preflight/releases/latest)
    # Convert URL to downloadable binary
    DL_URL="${LATEST_URL/tag/download}/preflight-linux-amd64"
    curl -Lo preflight "${DL_URL}"
    chmod 755 preflight
fi

# Split IMAGE on /
IFS=/ read -a parts <<< "${IMAGE}"

# If we're reading from a potentially-published image, need to
# extrapolate more arguments, create bespoke Docker credentials, etc.
if [ "${parts[0]}" = "scan.connect.redhat.com" ]; then

    echo "Image is at scan.connect.redhat.com - determining extra metadata"

    # Discover which product we're working on via the project_id in the image name
    # This bit of code is shared with files in the redhat-openshift repository
    conf_dir=/home/couchbase/openshift
    pushd ${conf_dir} > /dev/null
    for prod_dir in *; do
        if [ ! -e "${prod_dir}/project_id" ]; then
            continue
        fi

        pid=$(cat "${prod_dir}/project_id")
        if [ "${pid}" = "${parts[1]}" ]; then
            product=${prod_dir}
            echo "Identified product $product"
            break
        fi
    done
    popd > /dev/null

    if [ -z "${product}" ]; then
        echo "Project ID ${parts[1]} is not associated with any known product!"
        exit 2
    fi

    # Need to login for production (Red Hat) registry
    set +x
    docker login -u unused -p $(cat ${conf_dir}/${product}/registry_key) scan.connect.redhat.com

    # Produce filtered docker authentication so we don't send everything
    # to Red Hat
    cat ~/.docker/config.json \
        | jq '{auths: .auths | with_entries( select(.key == "scan.connect.redhat.com") ) }' \
        > temp-auths.json

    # Bizarrely this isn't the project ID that preflight requires, but we can
    # get the right one via their REST API
    echo "Looking up Red Hat Certification Project ID"
    pid=$( \
        curl --silent -H "X-API-KEY: ${APIKEY}" \
        https://catalog.redhat.com/api/containers/v1/projects/certification/pid/${parts[1]} \
        | jq -r '._id' \
    )

    # Set env vars so preflight can run
    export PFLT_CERTIFICATION_PROJECT_ID=${pid}
    export PFLT_DOCKERCONFIG=$(pwd)/temp-auths.json
    export PFLT_PYXIS_API_TOKEN=${APIKEY}
fi

if ${SUBMIT}; then
    # Must be a potentially-published image to submit
    if [ -z "${PFLT_DOCKERCONFIG}" ]; then
        echo "Must point to scan.connect.redhat.com to submit!"
        exit 2
    fi
    export EXTRA_PREFLIGHT_ARGS=-s
fi

echo
echo ::::::::::::: RUNNING PREFLIGHT :::::::::::::::::::
export PFLT_LOGFILE=./artifacts/preflight.log
./preflight check container ${IMAGE} ${EXTRA_PREFLIGHT_ARGS}
