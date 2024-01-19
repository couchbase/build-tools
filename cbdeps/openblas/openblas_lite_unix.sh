#!/bin/bash

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3
ARCH=$8

scriptdir="$(realpath $( dirname -- "$BASH_SOURCE"; ))";
case $PLATFORM in
    android) $scriptdir/openblas_lite_android.sh $ARCH $ROOT_DIR $INSTALL_DIR ;;
    *) echo "!!! Unknown Lite platform $PLATFORM !!!"; exit 1;;
esac