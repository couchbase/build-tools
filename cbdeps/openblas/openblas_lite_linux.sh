#!/bin/bash -e

ARCH=$1
ROOT_DIR=$2
INSTALL_DIR=$3

case $(uname -s) in
    Linux*) ;;
    *) echo "Not running on a Linux system, aborting..."; exit 4;;
esac

case $ARCH in
    x86_64) ;;
    aarch64);;
    *) echo "Invalid architecture $ARCH, aborting..."; exit 5;;
esac

# cmake should be guaranteed to us by the build process for cbdeps
# but check just in case
command -v cmake >/dev/null 2>&1 || echo >&2 "cmake not installed, aborting..."

mkdir -p $ROOT_DIR/openblas/build_$ARCH

echo
echo "====  Building Linux binary ==="
echo

pushd $ROOT_DIR/openblas/build_$ARCH > /dev/null
if [ "$ARCH" == "x86_64" ]; then 
    CMAKE_TARGET_LINE=
    CMAKE_DYNAMIC_TARGETS=-DDYNAMIC_LIST="EXCAVATOR;HASWELL;ZEN;SKYLAKEX;COOPERLAKE;SAPPHIRERAPIDS"
    DYNAMIC_ARCH=1
 else
    CMAKE_TARGET_LINE=-DTARGET=ARMV8
    CMAKE_DYNAMIC_TARGETS=
    DYNAMIC_ARCH=0
 fi

cmake \
    -DCMAKE_C_COMPILER=/opt/gcc-13.2.0/bin/gcc \
    -DBUILD_WITHOUT_LAPACK=0 \
    -DNOFORTRAN=1 \
    -DDYNAMIC_ARCH=$DYNAMIC_ARCH \
    $CMAKE_TARGET_LINE \
    $CMAKE_DYNAMIC_TARGETS \
    -DBUILD_LAPACK_DEPRECATED=0 \
    -DBUILD_WITHOUT_CBLAS=1 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
    -S ..

make -j$(nproc) install