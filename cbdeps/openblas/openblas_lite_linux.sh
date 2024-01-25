#!/bin/bash -e

ROOT_DIR=$1
INSTALL_DIR=$2

CMAKE_VER="3.28.1"

case $(uname -s) in
    Linux*) ;;
    *) echo "Not running on a Linux system, aborting..."; exit 4;;
esac

mkdir -p $ROOT_DIR/openblas/build

echo
echo " ======== Installing cbdeps ========"
echo

mkdir -p .tools
if [ ! -f $ROOT_DIR/.tools/cbdep ]; then
    curl -o $ROOT_DIR/.tools/cbdep http://downloads.build.couchbase.com/cbdep/cbdep.$(uname -s | tr "[:upper:]" "[:lower:]")-$(uname -m)
    chmod +x $ROOT_DIR/.tools/cbdep
fi

CMAKE="$ROOT_DIR/.tools/cmake-${CMAKE_VER}/bin/cmake"
if [ ! -f ${CMAKE} ]; then
    $ROOT_DIR/.tools/cbdep install -d .tools cmake ${CMAKE_VER}
fi

echo
echo "====  Building Linux binary ==="
echo

pushd $ROOT_DIR/openblas/build > /dev/null
$CMAKE \
 -DCMAKE_C_COMPILER=/opt/gcc-13.2.0/bin/gcc \
 -DBUILD_WITHOUT_LAPACK=0 \
 -DNOFORTRAN=1 \
 -DDYNAMIC_ARCH=1 \
 -DBUILD_LAPACK_DEPRECATED=0 \
 -DDYNAMIC_LIST="EXCAVATOR;HASWELL;ZEN;SKYLAKEX;COOPERLAKE;SAPPHIRERAPIDS" \
 -DBUILD_WITHOUT_CBLAS=1 \
 -DCMAKE_BUILD_TYPE=Release \
 -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
 -S ..

make -j$(nproc) install