#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PROFILE=$4
VERSION=$6
ARCH=$8
BD_MANIFEST=$9

PACKAGE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${PACKAGE_DIR}/../../utilities/shell-utils.sh"

# Get dependency versions from manifest annotations
CUDA_COMPLETE_VERSION=$(annot_from_manifest CUDA_COMPLETE_VERSION)
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

function install_cuda() {
    IFS="_" read -r CUDA_VERSION CUDA_DRIVER_VERSION <<< "${CUDA_COMPLETE_VERSION}"
    export CUDA_HOME=/home/couchbase/cuda_${CUDA_VERSION}
    export PATH=${CUDA_HOME}/bin:$PATH
    export LD_LIBRARY_PATH=${CUDA_HOME}/lib64:$LD_LIBRARY_PATH
    # if nvcc exist, assume cuda is already installed
    if [[ ! -f "${CUDA_HOME}/bin/nvcc" ]]; then
        if [[ "${ARCH}" == "aarch64" ]]; then
            RUN_FILE=cuda_${CUDA_COMPLETE_VERSION}_linux_sbsa.run
        else
            RUN_FILE=cuda_${CUDA_COMPLETE_VERSION}_linux.run
        fi
        curl -fsSL \
          -o cuda_linux.run \
          https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/${RUN_FILE}
        rm -rf ${CUDA_HOME}
        mkdir ${CUDA_HOME}
        sh cuda_linux.run --toolkit --installpath=${CUDA_HOME} --silent
        rm -f cuda_linux.run
    fi
}

OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')

# Build. The PROFILE is used to determine whether to build with GPU support
# and passed as FAISS_OPT_LEVEL. Currently supported values are
# "generic", "avx2", and "avx2-gpu".

OPT_LEVEL=$(echo ${PROFILE} | sed -e "s/-gpu//")
case "${OS_TYPE}" in
    "darwin")
        if [[ "${PROFILE}" == *"gpu"* ]]; then
            echo "Skipping GPU build on Darwin"
            exit 0 # Skip GPU build on Darwin
        fi
        ENABLE_GPU=OFF
        # Need OpenMP from LLVM as Apple, for some reason, omits it in XCode
        build_openmp
        ;;
    "linux")
        if [[ "${PROFILE}" == *"gpu"* ]]; then
            install_cuda
            ENABLE_GPU=ON
        else
            ENABLE_GPU=OFF
        fi
        # Need OpenBLAS on Linux
        download_openblas

        # Build with GCC 13 for latest hardware compatibility
        export CXX=/opt/gcc-13.2.0/bin/g++
        export CC=/opt/gcc-13.2.0/bin/gcc
        ;;
    *)
        echo "Unsupported OS: ${OS_TYPE}"
        exit 1
        ;;
esac

cd "${ROOT_DIR}"
cmake -B build -S "${ROOT_DIR}/faiss" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="${cmake_prefix_path}" \
    -DFAISS_ENABLE_GPU=${ENABLE_GPU} -DFAISS_ENABLE_PYTHON=OFF -DFAISS_ENABLE_C_API=ON \
    -DFAISS_OPT_LEVEL=${OPT_LEVEL} \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_RPATH='$ORIGIN'
cd build
make -j8 install VERBOSE=1

# Don't want pkgconfig
cd "${INSTALL_DIR}/lib"
rm -rf pkgconfig

# Do need to include openmp on Mac
if [[ "${OS_TYPE}" == "darwin" ]]; then
    cp -av "${ROOT_DIR}/openmp/lib/"* .
    pushd "${INSTALL_DIR}/include"
    cp -av "${ROOT_DIR}/openmp/include/"* .
    popd
fi

# package cuda libraries when building with ENABLE_GPU
if [[ "${ENABLE_GPU}" == "ON" ]]; then
    cp -av ${CUDA_HOME}/lib64/libcudart.so* ${INSTALL_DIR}/lib/.
    cp -av ${CUDA_HOME}/lib64/libcublas.so* ${INSTALL_DIR}/lib/.
    cp -av ${CUDA_HOME}/lib64/libcublasLt.so* ${INSTALL_DIR}/lib/.

    cp -av ${CUDA_HOME}/include/cuda_runtime.h ${INSTALL_DIR}/include/.
    cp -av ${CUDA_HOME}/include/cuda_runtime_api.h ${INSTALL_DIR}/include/.
    cp -av ${CUDA_HOME}/include/cublas_v2.h ${INSTALL_DIR}/include/.
    cp -av ${CUDA_HOME}/include/cublas.h ${INSTALL_DIR}/include/.
    cp -av ${CUDA_HOME}/include/cublasLt.h ${INSTALL_DIR}/include/.
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

    cat "${PACKAGE_DIR}/black-duck-manifest.yaml.in" \
        | sed -e "s/@@BD_VERSION@@/${BD_VERSION}/g" \
        | sed -e "s/@@OPENMP_VERSION@@/${LLVM_OPENMP_VERSION}/g" \
        | sed -e "s/@@OPENBLAS_VERSION@@/${OPENBLAS_VERSION}/g" \
        > "${BD_MANIFEST}"

    popd
fi
