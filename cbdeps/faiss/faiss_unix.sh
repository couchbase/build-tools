#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
VERSION=$6
ARCH=$8
BD_MANIFEST=$9

PACKAGE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${PACKAGE_DIR}/../../utilities/shell-utils.sh"

# Get dependency versions from manifest annotations
OPENBLAS_VERSION=$(annot_from_manifest OPENBLAS_VERSION)
LLVM_OPENMP_VERSION=$(annot_from_manifest LLVM_OPENMP_VERSION)



function build_openmp() {
    mkdir "${ROOT_DIR}/openmp"
    pushd "${ROOT_DIR}/openmp"

    # Checkout the LLVM OpenMP source code. Since the LLVM repo is
    # *enormous*, use some Git tricks to download only what we need, the
    # `openmp` and `cmake` directories:
    # 1. Clone the repo with no history except the one commit (tag) we
    #    want, not checking out any files.
    # 2. Use sparse-checkout to tell Git to check out only the two dirs
    #    we want.
    # 3. Finally checkout. The resulting tree is only ~30MB, vs. several
    # GB for a full clone. Thanks to:
    # <https://stackoverflow.com/a/52269934/98077>
    git clone --branch llvmorg-${LLVM_OPENMP_VERSION} \
        -n --depth=1 --filter=tree:0 \
        https://github.com/llvm/llvm-project src
    cd src
    git sparse-checkout set cmake openmp
    git checkout
    cd openmp

    # Build
    cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX="${ROOT_DIR}/openmp"
    cd build
    make -j8 install

    popd

    export cmake_prefix_path="${ROOT_DIR}/openmp"
}

function download_openblas() {
    # Grab OpenBLAS cbdeps package
    cbdep -p linux install \
        -d "${ROOT_DIR}/deps" \
        -C openblas ${OPENBLAS_VERSION}

    export cmake_prefix_path="${ROOT_DIR}/deps/openblas-${OPENBLAS_VERSION}"
}


# Compiler stuff - platform dependent
if [ "$(uname -s)" == "Darwin" ]; then
    # Need OpenMP from LLVM as Apple, for some reason, omits it in XCode
    build_openmp
else
    # Need OpenBLAS on Linux
    download_openblas

    # Build with GCC 13 for latest hardware compatibility
    export CMAKE_CXX_COMPILER=/opt/gcc-13.2.0/bin/g++
    export CMAKE_C_COMPILER=/opt/gcc-13.2.0/bin/gcc
fi

# Build
cd "${ROOT_DIR}/faiss"
cmake -B build \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="${cmake_prefix_path}" \
    -DFAISS_ENABLE_GPU=OFF -DFAISS_ENABLE_PYTHON=OFF -DFAISS_ENABLE_C_API=ON \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=ON
cd build
make -j8 install

# Don't want pkgconfig
cd "${INSTALL_DIR}/lib"
rm -rf pkgconfig

# Do need to include openmp on Mac
if [ "$(uname -s)" == "Darwin" ]; then
    cp -avi "${ROOT_DIR}/openmp/lib/"* .
    pushd "${INSTALL_DIR}/include"
    cp -avi "${ROOT_DIR}/openmp/include/"* .
    popd
fi

# Create BD_MANIFEST if requested
if [ -n "${BD_MANIFEST}" ]; then
    # BD may use slightly different version conventions, so we get that
    # from our manifest
    pushd "${ROOT_DIR}"
    BD_VERSION=$(annot_from_manifest BD_VERSION "${VERSION}")

    # OPENBLAS_VERSION is a cbdeps version including build number, so
    # strip that off
    OPENBLAS_VERSION=$(echo ${OPENBLAS_VERSION} | sed -e "s/-.*//")

    cat "${PACKAGE_DIR}/blackduck/black-duck-manifest.yaml.in" \
        | sed -e "s/@@BD_VERSION@@/${BD_VERSION}/g" \
        | sed -e "s/@@OPENMP_VERSION@@/${LLVM_OPENMP_VERSION}/g" \
        | sed -e "s/@@OPENBLAS_VERSION@@/${OPENBLAS_VERSION}/g" \
        > "${BD_MANIFEST}"

    popd
fi
