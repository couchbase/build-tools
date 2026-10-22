#!/bin/bash -ex

# Builds a Rust k8s-microservice product with cargo. cargo can't easily
# cross-compile the products' C dependencies, so a matrix job runs this in
# two stages:
#
#   build    in each matrix cell, natively on its architecture (x86_64 or
#            aarch64): installs protoc and the Rust toolchain, runs cargo
#            build, and writes
#            ${PRODUCT}/dist/<DIST_BINARY>-<arch>_VERSION-BLD_NUM plus a
#            .debug file of its symbols, for the job to publish to
#            latestbuilds.
#   package  after the matrix cells have completed: downloads both
#            architectures' binaries from BIN_BASE_URL (by default this
#            build's latestbuilds directory) into artifacts/bin/linux, adds
#            the product's LICENSE, Dockerfile and Dockerfile.rhel, and
#            writes ${PRODUCT}/dist/${PRODUCT}-image_VERSION-BLD_NUM.tgz of
#            them for util/build-k8s-images.sh to build the images from.
#
# Each product is described in product_settings below. The
# rust-toolchain.toml must pin the Rust version, and the
# manifest's PROTOC_VERSION annotation, if any, picks protoc.
#
# Usage: couchbase-k8s-microservice-cargo-build.sh build|package

# Sets ARCH to this machine's architecture, as Docker names it (amd64,
# arm64), and PRODUCT's settings. Paths are relative to ${PRODUCT}, where
# the manifest checks out its source:
#   DIST_BINARY   the name the binary ships as; required
#   CARGO_BINARY  the name cargo builds the binary as, used when cargo
#                 doesn't already build it as DIST_BINARY
product_settings() {
    CARGO_BINARY=
    DIST_BINARY=
    case "$(uname -m)" in
        x86_64) ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        *) ARCH="$(uname -m)" ;;
    esac
    case "${PRODUCT}" in
        couchbase-converge-mongodb)
            CARGO_BINARY=stellar-rosetta-rs
            DIST_BINARY=cbmcd
            ;;
        *)
            error "${PRODUCT} is not a known cargo-built product"
            ;;
    esac
}

# Installs into TMP_DIR, and puts on PATH, the protoc version the
# manifest's PROTOC_VERSION annotation specifies, if any.
install_protoc() {
    local version
    version=$(annot_from_manifest PROTOC_VERSION)
    if [ -z "${version}" ]; then
        return
    fi
    cbdep install -d "${TMP_DIR}" protoc ${version}
    export PATH="${TMP_DIR}"/protoc-${version}/bin:${PATH}
}

# Installs Rust toolchain into TMP_DIR, and puts on PATH.
# Identifies exact Rust version from rust-toolchain.toml.
# Usage: install_rust_toolchain <file>
install_rust_toolchain() {
    local toolchain_toml=$1
    local version
    if [ ! -f "${toolchain_toml}" ]; then
        error "${toolchain_toml} not found; it must pin the Rust version"
    fi
    version=$(awk -F'"' '$1 ~ /^channel/ { print $2; exit }' "${toolchain_toml}")
    if [[ ! ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Rust must pin an exact Rust version (eg. 1.97.1), found '${version}'"
    fi
    cbdep install -d "${TMP_DIR}" rust ${version}
    export PATH="${TMP_DIR}"/rust-${version}/bin:${PATH}
}

# Builds the release binaries
cargo_build() {
    # Cargo fetches the git dependencies over ssh with the system git.
    export CARGO_NET_GIT_FETCH_WITH_CLI=true
    pushd ${PRODUCT}
    PROD_VERSION=${VERSION} BLD_NUM=${BLD_NUM} cargo build --release --locked
    popd
    mkdir -p ${PRODUCT}/dist
    # Ship the binary as DIST_BINARY: as is if cargo already names it so,
    # otherwise renamed from CARGO_BINARY (eg. stellar-rosetta-rs).
    local built=${PRODUCT}/target/release/${DIST_BINARY}
    local versioned_binary=${DIST_BINARY}-${ARCH}_${VERSION}-${BLD_NUM}
    if [ ! -f "${built}" ]; then
        built=${PRODUCT}/target/release/${CARGO_BINARY}
    fi
    if [ ! -f "${built}" ]; then
        error "Could not find ${DIST_BINARY} or ${CARGO_BINARY} in ${PRODUCT}/target/release"
    fi
    cp "${built}" ${PRODUCT}/dist/${versioned_binary}
    if command -v objcopy >/dev/null 2>&1; then
        objcopy --only-keep-debug "${PRODUCT}/dist/${versioned_binary}" "${PRODUCT}/dist/${versioned_binary}.debug"
        objcopy --strip-debug --add-gnu-debuglink="${PRODUCT}/dist/${versioned_binary}.debug" "${PRODUCT}/dist/${versioned_binary}"
    else
        warn "objcopy not found - shipping ${versioned_binary} with full debug symbols"
    fi
    # The binary, and its .debug file if objcopy made one
    chmod +x "${PRODUCT}/dist/${versioned_binary}"*
}

# Writes dist/${PRODUCT}-image_VERSION-BLD_NUM.tgz
package_image() {
    pushd ${PRODUCT}
    BIN_BASE_URL="${BIN_BASE_URL:-https://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}/}"

    rm -rf artifacts
    mkdir -p artifacts/bin/linux dist
    for arch in amd64 arm64; do
        curl --fail --show-error --silent -L \
            -o artifacts/bin/linux/${DIST_BINARY}-${arch} \
            ${BIN_BASE_URL}/${DIST_BINARY}-${arch}_${VERSION}-${BLD_NUM} \
            || error "Failed to download ${BIN_BASE_URL}/${DIST_BINARY}-${arch}_${VERSION}-${BLD_NUM}"
    done
    cp LICENSE artifacts/.
    cp docker/Dockerfile artifacts/.
    cp docker/Dockerfile.rhel artifacts/.
    tar -C artifacts -czf dist/${PRODUCT}-image_${VERSION}-${BLD_NUM}.tgz .
    popd
}

# Main

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))
source ${script_dir}/../../utilities/shell-utils.sh

# Create temp directory to install tools in, in the home directory (eg.
# /home/couchbase) rather than the workspace: a matrix job's workspace path
# holds its axis values, eg. ".../ARCH/master&&x86_64&&linux", and the Rust
# install fails on the "&&". It is removed when this script exits.
TMP_DIR=$(mktemp -d "${HOME}/cargo-build.XXXXXXXX")
trap 'rm -rf "${TMP_DIR}"' EXIT

product_settings

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

case "$1" in
    build)
        install_protoc
        install_rust_toolchain ${PRODUCT}/rust-toolchain.toml
        cargo_build
        ;;
    package)
        package_image
        ;;
    *)
        error "Usage: $(basename $0) build|package"
        ;;
esac
