#!/bin/bash

# Copyright 2017-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.

set -ex

# Re configure and build twice:
# - once for Release build (fully optimized, no runtime assertions)
# - once for Debug build (optimisation disable, runtime asserts enabled)
root_dir=$1
configure_args=$2
install_dir=$3
install_suffix=$4
version=$5

cd "${root_dir}/jemalloc"

# Always want these args
configure_args+=" --prefix=${install_dir}"

# Profiling only supported on non-Darwin.
if [ $(uname -s) != "Darwin" ]; then
    configure_args+=" --enable-prof"
fi

./autogen.sh ${configure_args} \
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

# Fix up Rpath on Linux - impossible to pass via --with-rpath due to
# escaping hell
if [ $(uname -s) = "Linux" ]; then
    chrpath -r '$ORIGIN' ${install_dir}/lib/libjemalloc${install_suffix}.so.2
    chrpath -r '$ORIGIN' ${install_dir}/lib/libjemalloc${install_suffix}d.so.2
fi

# Fix up macOS dylib names
if [ $(uname -s) = "Darwin" ]; then
    install_name_tool -id @rpath/libjemalloc${install_suffix}.2.dylib \
        ${install_dir}/lib/libjemalloc${install_suffix}.2.dylib
    install_name_tool -id @rpath/libjemalloc${install_suffix}d.2.dylib \
        ${install_dir}/lib/libjemalloc${install_suffix}d.2.dylib
fi

# Create JemallocConfigVersion.cmake to go with our JemallocConfig.cmake
cmake -D OUTPUT=${install_dir}/cmake/ \
    -D VERSION=${version} \
    -D PACKAGE=Jemalloc${install_suffix} \
    -P "${root_dir}/build-tools/cbdeps/scripts/create_config_version.cmake"