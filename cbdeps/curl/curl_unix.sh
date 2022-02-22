#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3
ARCH=$8

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd ${ROOT_DIR}/curl

# Dependencies
OPENSSL_VER=1.1.1l-1
ZLIB_VER=1.2.11-8
CBDEP_TOOL_VERS=1.0.4

DEPSDIR=${WORKSPACE}/deps
rm -rf ${DEPSDIR}
mkdir -p ${DEPSDIR}

get_dep() {
    dep=$1
    ver=$2

    # Assign directory variable for others to reference
    dep_DIR=${DEPSDIR}/${dep}-${ver}
    eval "${dep}_DIR=${dep_DIR}"

    # See if it's already in local .cbdepscache
    DEP_CACHE=/home/couchbase/.cbdepscache/${dep}*-${ver}.tgz
    if [ ! -z "${LOCAL_BUILD}" -a -f ${DEP_CACHE} ]; then
        mkdir -p ${dep_DIR}
        tar xzf ${DEP_CACHE} -C ${dep_DIR}
    else
        cbdep -p ${PLATFORM} install -d "${DEPSDIR}" ${dep} ${ver}
    fi
}

get_dep openssl ${OPENSSL_VER}
rm -rf ${openssl_DIR}/lib/pkgconfig
get_dep zlib ${ZLIB_VER}
rm -rf ${zlib_DIR}/lib/pkgconfig

# Build
if [[ $(uname -s) != "Darwin" ]]; then
    export LDFLAGS="-Wl,-rpath,'\$\$ORIGIN/../lib'"
    export LD_LIBRARY_PATH="${openssl_DIR}/lib ${zlib_DIR}/lib"
fi
export LDFLAGS="${LDFLAGS} -L${openssl_DIR}/lib -L${zlib_DIR}/lib"
export CPPFLAGS="-I${openssl_DIR}/include -I${zlib_DIR}/include"

autoreconf -i
./configure --prefix=${INSTALL_DIR} \
            --disable-debug \
            --enable-optimize \
            --disable-warnings \
            --disable-werror \
            --disable-curldebug \
            --enable-shared \
            --disable-static \
            --without-libssh2 \
            --with-ssl=${openssl_DIR} \
            --with-zlib=${zlib_DIR}
make all
make install

# Remove unneeded files
rm -rf ${INSTALL_DIR}/bin/curl-config
rm -rf ${INSTALL_DIR}/lib/pkgconfig
rm -rf ${INSTALL_DIR}/share
rm -f ${INSTALL_DIR}/lib/libcurl.la

if [[ $(uname -s) == "Darwin" ]]; then
    # Fix rpath for macOS libraries
    install_name_tool -id @rpath/libcurl.4.dylib ${INSTALL_DIR}/lib/libcurl.4.dylib
    install_name_tool -change ${INSTALL_DIR}/lib/libcurl.4.dylib @executable_path/../lib/libcurl.4.dylib ${INSTALL_DIR}/bin/curl
    install_name_tool -add_rpath @executable_path/../lib ${INSTALL_DIR}/bin/curl
else
    # Utilize wrapper script for Linux
    mv ${INSTALL_DIR}/bin/curl ${INSTALL_DIR}/bin/curl.real
    cp -a ${SCRIPT_DIR}/curl_wrapper.sh ${INSTALL_DIR}/bin/curl
fi
