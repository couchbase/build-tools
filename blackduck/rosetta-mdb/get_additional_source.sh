#!/bin/bash -ex

# Install the exact toolchain pinned in rust-toolchain.toml, rather than
# whatever "cargo" happens to be on PATH.
RUST_VERSION=$(grep '^channel' rosetta-mdb/rust-toolchain.toml | sed -E 's/.*"(.*)".*/\1/')
chk_set RUST_VERSION

TOOLDIR=$(mktemp -d -q --tmpdir=$(pwd) toolsXXXXX)

cbdep install -d ${TOOLDIR} rust ${RUST_VERSION}
export PATH=${TOOLDIR}/rust-${RUST_VERSION}/bin:${PATH}

# Require at least 11.5.1 (needed for detect.cargo.dependency.types.excluded
# to be honored), but don't clobber a newer version the Jenkins job may have
# set.
MIN_DETECT_JAR_VERSION=11.5.1
if [ -z "${DETECT_JAR_VERSION}" ] || [ "$(printf '%s\n' "${MIN_DETECT_JAR_VERSION}" "${DETECT_JAR_VERSION}" | sort -V | head -n1)" != "${MIN_DETECT_JAR_VERSION}" ]; then
    DETECT_JAR_VERSION=${MIN_DETECT_JAR_VERSION}
fi
export DETECT_JAR_VERSION
