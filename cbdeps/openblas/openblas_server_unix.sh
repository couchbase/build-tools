#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
ARCH=$8

cd "${ROOT_DIR}/openblas"

# Build with GCC 13 for latest hardware compatibility
export CMAKE_CXX_COMPILER=/opt/gcc-13.2.0/bin/g++
export CMAKE_C_COMPILER=/opt/gcc-13.2.0/bin/gcc

# These options are derived from the conda-forge recipe for OpenBlas - I
# figure they know something about compiling things that will work on a
# wide variety of architectures.
# https://github.com/conda-forge/openblas-feedstock/blob/main/recipe/build.sh
if [ "${ARCH}" = x86_64 ]; then
  TARGET=PRESCOTT
  DYNAMIC_ARCH=ON
else
  TARGET=ARMV8
  DYNAMIC_ARCH=OFF
fi

cmake -B build \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_TESTING=OFF \
  -DTARGET=${TARGET} -DDYNAMIC_ARCH=${DYNAMIC_ARCH} -DBINARY=64 \
  -DUSE_THREAD=ON -DNUM_THREADS=128
cd build
make -j8 install

cd "${INSTALL_DIR}/lib"
rm -rf pkgconfig
