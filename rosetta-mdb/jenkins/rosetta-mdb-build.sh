#!/bin/bash -ex
# This script is intended to be run by Jenkins.
# If it needs to run locally for testing, $WORKSPACE needs to be set
# rosetta-mdb, rosetta-mdb-crs, and build-tools repositories should be
# checked out under $WORKSPACE

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))
source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

SRC_DIR=${WORKSPACE}/${PRODUCT}
CORE_DIR=${WORKSPACE}/rosetta-mdb-crs
if [ ! -d "${SRC_DIR}" ] || [ ! -d "${CORE_DIR}" ]; then
	echo "Expected source directories ${SRC_DIR} and ${CORE_DIR} doesn't exist"
	exit 1
fi

# annot_from_manifest looks for manifest.xml/.repo in the current directory,
# so it has to run from the workspace root, before we cd into ${SRC_DIR}.
# rosetta-inst needs protoc on PATH to compile etcd-client's protos.
cd ${WORKSPACE}
PROTOC_VERSION=$(annot_from_manifest PROTOC_VERSION)
chk_set PROTOC_VERSION

# Install the exact toolchain pinned in rust-toolchain.toml, rather than
# whatever "cargo" happens to be on PATH.
RUST_VERSION=$(grep '^channel' ${SRC_DIR}/rust-toolchain.toml | sed -E 's/.*"(.*)".*/\1/')
chk_set RUST_VERSION

TOOLDIR=$(mktemp -d -q --tmpdir=$(pwd) toolsXXXXX)

cbdep install -d ${TOOLDIR} rust ${RUST_VERSION}
export PATH=${TOOLDIR}/rust-${RUST_VERSION}/bin:${PATH}

cbdep install -d ${TOOLDIR} protoc ${PROTOC_VERSION}
export PATH=${TOOLDIR}/protoc-${PROTOC_VERSION}/bin:${PATH}

cd "${SRC_DIR}"

cargo build --release --locked

# This script builds natively - Jenkins runs it once per architecture (amd64,
# arm64), so tag each binary with its arch to keep the two apart.
case "$(uname -m)" in
x86_64) ARCH=amd64 ;;
aarch64 | arm64) ARCH=arm64 ;;
*) error "Unsupported architecture: $(uname -m)" ;;
esac

DIST_DIR="${SRC_DIR}/dist"
mkdir -p "${DIST_DIR}"

# Cargo build currently produces stellar-rosetta-rs
# The binary will be produced as cbmcd in the future
# This renaming logic should be removed by then
if [ ! -f "target/release/cbmcd" ] && [ -f "target/release/stellar-rosetta-rs" ]; then
	mv "target/release/stellar-rosetta-rs" "target/release/cbmcd"
fi
if [ ! -f "target/release/cbmcd" ]; then
	error "Could not find built binary (expected cbmcd or stellar-rosetta-rs) in target/release"
fi

DIST_BIN="${DIST_DIR}/cbmcd-${ARCH}_${VERSION}_${BLD_NUM}"
cp "target/release/cbmcd" "${DIST_BIN}"

# [profile.release] debug = true embeds full debug symbols for profiling
# (see docs/performance.md), which is why target/release/cbmcd itself is
# left untouched. Strip only the dist copy, keeping the symbols alongside
# it in a separate .debug file so they can still be attached later.
if command -v objcopy >/dev/null 2>&1; then
	objcopy --only-keep-debug "${DIST_BIN}" "${DIST_BIN}.debug"
	objcopy --strip-debug --add-gnu-debuglink="${DIST_BIN}.debug" "${DIST_BIN}"
else
	warn "objcopy not found - shipping ${DIST_BIN} with full debug symbols"
fi
