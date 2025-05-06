#!/bin/bash -e

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

# Basic help information
function show_help {
    echo "Usage: $0 <options>"
    echo "Options:"
    echo "  -i : Product, eg. couchbase-server (Required)"
    echo "  -v : Version to check (eg. 7.2.0) (Required)"
    exit 0
}

# Parse options and ensure required ones are there
while getopts :p:v:b:h opt; do
    case ${opt} in
        p) PRODUCT="$OPTARG"
           ;;
        v) VERSION="$OPTARG"
           ;;
        h) show_help
           ;;
        \?) # Unrecognized option, show help
            echo -e \\n"Invalid option: ${OPTARG}" 1>&2
            show_help
    esac
done

if [[ -z "$PRODUCT" ]]; then
    echo "Product (-p) is required"
    exit 1
fi

if [[ -z "$VERSION" ]]; then
    echo "Full version (-v) is required"
    exit 1
fi

# Ask RHCC for tag numbers and pick out the last one
PYSCRIPT=$(cat <<EOF
import sys
import json

tags = json.load(sys.stdin)["Tags"]
highest = 0
for tag in tags:
    if tag.startswith("$VERSION"):
        try:
            # We check the second component after a dash - this will
            # pick up the "b" in both X.Y.Z-b and X.Y.Z-b-arm64 images,
            # which we want for now while multi-arch isn't supported by
            # RHCC
            bldno = int(tag.split('-')[1])
        except (ValueError, IndexError):
            continue
        if bldno > highest:
            highest = bldno
print (highest + 1)
EOF
)

# Use a job specific auth file for skopeo
export REGISTRY_AUTH_FILE=$(pwd)/docker-auth.json

CONFFILE=~/.docker/rhcc-metadata.json

product_path=".products.\"${PRODUCT}\""
project_id=$(jq -r "${product_path}.project_id" "${CONFFILE}")
registry_key=$(jq -r "${product_path}.registry_key" "${CONFFILE}")
image_base=quay.io/redhat-isv-containers/${project_id}

# Login to RHCC
skopeo login -u redhat-isv-containers+${project_id}-robot -p ${registry_key} quay.io &>/dev/null

# Get and filter tag list
skopeo list-tags docker://${image_base} --override-arch arm64 --override-os linux | python -c "$PYSCRIPT"
