#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

# Define target platforms and architectures as "os/arch"
TARGETS=(
  "linux/amd64"
  "linux/arm64"
  "darwin/amd64"
  "darwin/arm64"
  "windows/amd64"
)

GOVERSION=$(gover_from_manifest)

TOOLDIR=$(mktemp -d -q --tmpdir=$(pwd) toolsXXXXX)

if [ ! -z "${GOVERSION}" ]; then
    # Create temp directory in WORKSPACE to install golang
    cbdep install -d ${TOOLDIR} golang ${GOVERSION}
    export PATH=${TOOLDIR}/go${GOVERSION}/bin:${PATH}
fi
pushd "${PRODUCT}"
DIST_DIR="dist"
mkdir "${DIST_DIR}"
for target in "${TARGETS[@]}"; do
    # Split the "os/arch" string into separate variables
    PLATFORM="${target%/*}"
    ARCH="${target#*/}"

    # Append .exe extension if compiling for Windows
    OUTPUT_NAME="${PRODUCT}-${PLATFORM}-${ARCH}"
    if [ "${PLATFORM}" = "windows" ]; then
        OUTPUT_NAME="${OUTPUT_NAME}.exe"
    fi

    echo "Building ${OUTPUT_NAME}..."
    GOOS="${PLATFORM}" GOARCH="${ARCH}" CGO_ENABLED=0 \
        go build -o "${DIST_DIR}/${OUTPUT_NAME}" -ldflags="-s -w" ./
done
popd
