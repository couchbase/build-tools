#!/bin/bash

ANDROID_ARCH=$1
ROOT_DIR=$2
INSTALL_DIR=$3

NDK_VERSION="26b"
ANDROID_API_VERSION="23"
NDK_HOME="$ROOT_DIR/tools/android-ndk-r$NDK_VERSION"

NDK_DOWNLOAD="https://dl.google.com/android/repository/android-ndk-r$NDK_VERSION-linux.zip"

case $(uname -s) in
    Linux*);;
    *) echo "This script is only supported on Linux, aborting..."; exit 4;;
esac

# Download command line tools to get the android NDK in order to build
if [ ! -d $NDK_HOME ]; then
    echo "Android NDK $NDK_VERSION not found, downloading..."
    curl -Lf -o $ROOT_DIR/tools/android-ndk.zip $NDK_DOWNLOAD
    pushd $ROOT_DIR/tools > /dev/null
    echo "Extracting..."
    unzip -q android-ndk.zip
    rm android-ndk.zip
    popd > /dev/null
fi

pushd "${ROOT_DIR}/openblas"
pwd

function validate_arch() {
    case $ANDROID_ARCH in
        armv7a)
            ANDROID_ABI="eabi"
            MAKE_ARGS="TARGET=ARMV7 ARM_SOFTFP_ABI=1"
            ;;
        aarch64)
            MAKE_ARGS="TARGET=CORTEXA57"
            ;;
        i686)
            MAKE_ARGS="TARGET=ATOM"
            ;;
        x86_64)
            MAKE_ARGS="TARGET=ATOM BINARY=64"
            ;;
        *)
            echo "Invalid arch $ANDROID_ARCH, valid choices are (armv7a, aarch64, i686, x86_64)!"
            exit 2
            ;;
    esac
}

validate_arch

type make || (echo "make not found on system, aborting..."; exit 3)

echo
echo "====  Building Android $ANDROID_API_VERSION binary for $ANDROID_ARCH ==="
echo

make $MAKE_ARGS BUILD_LAPACK_DEPRECATED=0 NO_LAPACKE=1 BUILD_RELAPACK=0 NO_SHARED=1 HOSTCC=gcc \
 CC=$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/$ANDROID_ARCH-linux-android$ANDROID_ABI$ANDROID_API_VERSION-clang \
 RANLIB=$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ranlib \
 AR=$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar \
 libs netlib

make NO_SHARED=1 PREFIX="" DESTDIR=${INSTALL_DIR} install