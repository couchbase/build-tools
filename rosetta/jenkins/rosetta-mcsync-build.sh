#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

# mcsync only ships for Linux today.
TARGETS=(
  "linux/amd64"
  "linux/arm64"
)

PKG="./cmd/mcsync"
LDPKG="github.com/couchbaselabs/mcsync/internal/cli"

pushd ${WORKSPACE}/mcsync
GIT_COMMIT__SHA=$(git rev-parse --short HEAD)

# Go version is pinned by go.mod, not the manifest.
GOVERSION=$(grep "^go " go.mod | cut -d " " -f2)
# go.mod may specify just a major.minor version (eg. "1.27") rather than
# a fully-qualified patch release. In that case, resolve it to the latest
# stable patch release for that minor version via the official Go
# downloads API.
if [[ ! ${GOVERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    REQUESTED_GOVERSION="${GOVERSION}"
    GOVERSION=$(curl -sf "https://go.dev/dl/?mode=json&include=all" | \
        jq -r '.[].version' | \
        grep -E "^go${REQUESTED_GOVERSION}\.[0-9]+$" | \
        sort -V | tail -1)
    GOVERSION=${GOVERSION#go}
    if [[ ! ${GOVERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Could not resolve a stable patch release for Go version ${REQUESTED_GOVERSION}" >&2
        exit 1
    fi
fi
TOOLDIR=$(mktemp -d -q --tmpdir=${WORKSPACE} toolsXXXXX)
cbdep install -d ${TOOLDIR} golang ${GOVERSION}
export PATH=${TOOLDIR}/go${GOVERSION}/bin:${PATH}

DIST_DIR="dist"
mkdir "${DIST_DIR}"
for target in "${TARGETS[@]}"; do
    # Split the "os/arch" string into separate variables
    PLATFORM="${target%/*}"
    ARCH="${target#*/}"
    make build-static VERSION=v${VERSION}-${BLD_NUM}-${GIT_COMMIT__SHA} GOARCH=${ARCH} GOOS="${PLATFORM}"
    mv bin/mcsync dist/mcsync-${ARCH}_${VERSION}-${BLD_NUM}
    chmod +x dist/mcsync-${ARCH}_${VERSION}-${BLD_NUM}
done
popd
