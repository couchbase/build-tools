#!/bin/bash -e

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3

CURL_VER=8.9.1-1
OPENSSL_VER=3.1.4-1
ZLIB_VER=1.2.13-2

cd ${ROOT_DIR}/AWSSDK

if [ $PLATFORM = "linux" ]; then
    export CC=/opt/gcc-13.2.0/bin/gcc
    export CXX=/opt/gcc-13.2.0/bin/gcc
fi

add_cbdep() {
    dep=$1
    ver=$2
    cbdep -p ${PLATFORM} install -C -d ${ROOT_DIR}/deps ${dep} ${ver}
    export CMAKE_PREFIX_PATH="${ROOT_DIR}/deps/${dep}-${ver};${CMAKE_PREFIX_PATH}"
}

add_cbdep curl ${CURL_VER}
add_cbdep openssl ${OPENSSL_VER}
add_cbdep zlib ${ZLIB_VER}

# The aws-sdk-cpp CMake config uses the FindCURL module to find curl, but it
# tends to find the system curl instead of the one we want. Experimentally,
# overriding PC_CURL_LIBRARY_DIRS seems to force it to use the right one.
cmake -G Ninja -B build \
    -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}" \
    -DPC_CURL_LIBRARY_DIRS=${ROOT_DIR}/deps/curl-${CURL_VER}/lib \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_ONLY="s3-crt;s3;awstransfer;transfer" \
    -DAWS_SDK_WARNINGS_ARE_ERRORS=OFF -DENABLE_TESTING=OFF
cmake --build build --target install
