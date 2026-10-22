#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

GOVERSION=$(gover_from_manifest)

# If the manifest doesn't specify a Go version, use the one the
# product's go.mod asks for - a "toolchain" directive if present,
# otherwise the "go" directive.
if [ -z "${GOVERSION}" -a -f "${PRODUCT}/go.mod" ]; then
    GOVERSION=$(awk '$1 == "toolchain" { sub(/^go/, "", $2); print $2; exit }' "${PRODUCT}/go.mod")
    if [ -z "${GOVERSION}" ]; then
        GOVERSION=$(awk '$1 == "go" { print $2; exit }' "${PRODUCT}/go.mod")
    fi
    # go.mod may specify just a major.minor version (eg. "1.27"); if so,
    # use the latest stable patch release of it from the Go downloads API.
    if [[ ${GOVERSION} =~ ^[0-9]+\.[0-9]+$ ]]; then
        REQUESTED_GOVERSION=${GOVERSION}
        GOVERSION=$(
            curl --silent --show-error --fail "https://go.dev/dl/?mode=json&include=all" \
            | jq --raw-output '.[].version' \
            | grep -E "^go${REQUESTED_GOVERSION//./\\.}\.[0-9]+$" \
            | sed 's/^go//' | sort -V | tail -1
        )
        status "Resolved Go ${REQUESTED_GOVERSION} from go.mod to ${GOVERSION}"
    fi
    if [[ ! ${GOVERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Could not determine an exact Go version from ${PRODUCT}/go.mod, found '${GOVERSION}'"
    fi
fi

TOOLDIR=$(mktemp -d -q --tmpdir=$(pwd) toolsXXXXX)

if [ ! -z "${GOVERSION}" ]; then
    # Create temp directory in WORKSPACE to install golang
    cbdep install -d ${TOOLDIR} golang ${GOVERSION}
    export PATH=${TOOLDIR}/go${GOVERSION}/bin:${PATH}
fi

for dep in protoc; do
    ver=$(annot_from_manifest ${dep}_VERSION)
    if [ ! -z "${ver}" ]; then
        cbdep install -d ${TOOLDIR} ${dep} ${ver}
        export PATH=${TOOLDIR}/${dep}-${ver}/bin:${PATH}
    fi
done

cd ${PRODUCT}
# Also pass GOVERSION to Make, since some projects expect to find it there
make GO_VERSION=${GOVERSION} dist
