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

tags = json.load(sys.stdin)["tags"]
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

"${script_dir}/get-tag-list.sh" ${PRODUCT} | python -c "$PYSCRIPT"
