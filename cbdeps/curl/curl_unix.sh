#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2

cd ${ROOT_DIR}/curl

# Openssl dependency
OPENSSL_VER=1.1.1d-cb2
CBDEP_TOOL_VERS=0.9.15

# Download openssl via cbdeps tool
CBDEP_BIN_CACHE=/home/couchbase/.cbdepscache/cbdep/${CBDEP_TOOL_VERS}/cbdep-${CBDEP_TOOL_VERS}-linux
DEPSDIR=${WORKSPACE}/deps
rm -rf ${DEPSDIR}
OPENSSLDIR=${DEPSDIR}/openssl-${OPENSSL_VER}

if [[ ! -f ${CBDEP_BIN_CACHE} ]]; then
    if [ $(uname -s) = "Darwin" ]; then
        CBDEP_URL=https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VERS}/cbdep-${CBDEP_TOOL_VERS}-darwin
    else
        CBDEP_URL=https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VERS}/cbdep-${CBDEP_TOOL_VERS}-linux
    fi
    curl -o /tmp/cbdep ${CBDEP_URL}
else
   cp ${CBDEP_BIN_CACHE} /tmp/cbdep
fi

# Support escrow automation
CBDEP_OPENSSL_CACHE=/home/couchbase/.cbdepscache/openssl*-${OPENSSL_VER}.tgz
if [ ! -z "${LOCAL_BUILD}" -a -f ${CBDEP_OPENSSL_CACHE} ]; then
    mkdir -p ${OPENSSLDIR}
    tar xzf ${HOME}/.cbdepscache/openssl*-${OPENSSL_VER}.tgz -C ${OPENSSLDIR}
else
    chmod +x /tmp/cbdep
    /tmp/cbdep install -d "${DEPSDIR}" openssl ${OPENSSL_VER}
fi

rm -rf ${OPENSSLDIR}/lib/pkgconfig

# Build
if [[ $(uname -s) != "Darwin" ]]; then
    export LDFLAGS="-Wl,-rpath,'\$\$ORIGIN/../lib'"
    export LD_LIBRARY_PATH="${OPENSSLDIR}"/lib
    export CPPFLAGS="-I${OPENSSLDIR}/include"
fi
export LDFLAGS="${LDFLAGS} -L${OPENSSLDIR}/lib"
export CPPFLAGS="-I${OPENSSLDIR}/include"

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
            --with-ssl=${OPENSSLDIR}
make all
make install

# Remove unneeded files
rm -rf ${INSTALL_DIR}/bin/curl-config
rm -rf ${INSTALL_DIR}/lib/pkgconfig
rm -rf ${INSTALL_DIR}/share
rm -f ${INSTALL_DIR}/lib/libcurl.la

# Fix rpath for macOS libraries
if [[ $(uname -s) == "Darwin" ]]; then
    install_name_tool -id @rpath/libcurl.4.dylib ${INSTALL_DIR}/lib/libcurl.4.dylib
    install_name_tool -change ${INSTALL_DIR}/lib/libcurl.4.dylib @executable_path/../lib/libcurl.4.dylib ${INSTALL_DIR}/bin/curl
fi
