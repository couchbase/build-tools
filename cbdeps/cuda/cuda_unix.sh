#!/bin/bash -ex

set -x

# Copyright 2021-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.

INSTALL_DIR="${1}"
ROOT_DIR="${2}"
VERSION="${6}"
ARCH="${8}"

mkdir -p "${INSTALL_DIR}"/lib
mkdir -p "${INSTALL_DIR}"/include

redist_base_url="https://developer.download.nvidia.com/compute/cuda/redist"
curl -fLO "${redist_base_url}"/redistrib_"${VERSION}".json
if [ $? -ne 0 ]; then
    echo "Error: Failed to download from ${redist_base_url}/redistrib_${VERSION}.json"
    exit 1
fi
for pkg in cuda_cudart libcublas; do
    pkg_relative_path=$(cat redistrib_"${VERSION}".json | \
        jq -r --arg pkg "${pkg}" --arg arch "linux-${ARCH}" '.[$pkg][$arch].relative_path')
    curl -fLO "${redist_base_url}"/"${pkg_relative_path}"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to download from ${redist_base_url}/${pkg_relative_path}"
        exit 1
    fi
    pkg_file=$(echo "${pkg_relative_path}" |awk -F '/' '{print $NF}')
    pkg_dir="${pkg_file%.tar.xz}"
    # remove pkg_dir in case if anything is left around from a previous broken build.
    rm -rf "${pkg_dir}"
    tar xf "${pkg_file}"
    cp -rp "${pkg_dir}"/include/* "${INSTALL_DIR}"/include/.
    if [[ "${pkg}" == "libcublas" ]]; then
        cp -pP "${pkg_dir}"/lib/libcublas*.so* "${INSTALL_DIR}"/lib/.
    else
        cp -pP "${pkg_dir}"/lib/libcudart.so* "${INSTALL_DIR}"/lib/.
    fi
    rm -rf "${pkg_dir}" "${pkg_file}"
done

rm -f redistrib_"${VERSION}".json



