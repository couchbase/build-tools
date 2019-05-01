#!/bin/bash -e

INSTALL_DIR=$1

# Openssl dependency
OPENSSL_VERS=1.1.1b-cb2
CBDEP_TOOL_VERS=0.9.5

# Download openssl via cbdeps tool
CBDEP_BIN_CACHE=/home/couchbase/.cbdepscache/cbdep/${CBDEP_TOOL_VERS}/cbdep-${CBDEP_TOOL_VERS}-linux
DEPS=${WORKSPACE}/deps
WITH_SSL_OPTION="--with-ssl=${DEPS}/openssl-${OPENSSL_VER}"

CBDEP_BIN_CACHE=/home/couchbase/.cbdepscache/cbdep/${CBDEP_TOOL_VERS}/cbdep-${CBDEP_TOOL_VERS}-linux

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

chmod +x /tmp/cbdep
/tmp/cbdep install -d "${DEPS}" openssl ${OPENSSL_VERS}

# Build
if [[ $(uname -s) != "Darwin" ]]; then
    export LDFLAGS="-Wl,-rpath,'\$\$ORIGIN/../lib'"
fi

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
            ${WITH_SSL_OPTION}
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
