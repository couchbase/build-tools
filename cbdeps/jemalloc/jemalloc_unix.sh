#!/bin/bash

# Copyright 2017-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.

set -e

INSTALL_DIR=$1
ROOT_DIR=$2

# Re configure and build twice:
# - once for Release build (fully optimized, no runtime assertions)
# - once for Debug build (optimisation disable, runtime asserts enabled.
build_jemalloc() {
    local configure_args=$1
    local install_dir=$2
    local install_suffix=$3

    # Profiling only supported on non-Darwin.
    if [ $(uname -s) != "Darwin" ]; then
        configure_args+=" --enable-prof"
    fi

    ./autogen.sh ${configure_args} \
        --prefix=${install_dir} \
        --with-install-suffix=${install_suffix}
    make -j8 build_lib_shared
    make -j8 check
    make install_lib_shared install_include install_bin

    # Note that jemalloc --with-debug by default disables all optimisations (-O0).
    # This has a significant performance hit; we mostly want --with-debug for
    # runtime assertions. As such, turn back on "optimise for debug" (-Og).
    # The "d" at the end of install_suffix isn't a typo.
    CFLAGS=-Og ./autogen.sh ${configure_args} \
        --enable-debug \
        --prefix=${install_dir} \
        --with-install-suffix=${install_suffix}d
    make -j8 build_lib_shared
    make -j8 check
    # No need to re-install bin or include; they'll be the same
    make install_lib_shared

    # Fix up installed jemalloc.h if it got renamed
    if [ ! -z "${install_suffix}" ]; then
        pushd "${install_dir}/include/jemalloc"
        mv jemalloc${install_suffix}.h jemalloc.h
        popd
    fi

    # Fix up macOS dylib names
    if [ $(uname -s) = "Darwin" ]; then
        install_name_tool -id @rpath/libjemalloc${install_suffix}.2.dylib \
            ${install_dir}/lib/libjemalloc${install_suffix}.2.dylib
        install_name_tool -id @rpath/libjemalloc${install_suffix}d.2.dylib \
            ${install_dir}/lib/libjemalloc${install_suffix}d.2.dylib
    fi
}

cd "${ROOT_DIR}/jemalloc"

# Build the main installation with je_ symbol prefix
build_jemalloc "--with-jemalloc-prefix=je_ \
   --disable-cache-oblivious \
   --disable-zone-allocator \
   --disable-initial-exec-tls \
   --disable-cxx" \
   "${INSTALL_DIR}" \
   ""

# Create alternative libs without je_ prefix
build_jemalloc "--with-jemalloc-prefix=" "${INSTALL_DIR}/noprefix" "_noprefix"
