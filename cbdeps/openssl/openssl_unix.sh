#!/bin/bash
set -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3
PROFILE=$4
VERSION=$5
ARCH=$8

cd "${ROOT_DIR}/openssl"

ENABLE_FIPS=""

PREFIX=/opt/couchbase
OPENSSLDIR=${INSTALL_DIR}

if [ -f 'VERSION.dat' ]; then
    # openssl 3.x.x
    OPENSSLDIR=${PREFIX}/etc/openssl
    DYLIB_VER="3"
    NO_SSL2=""
    if [[ "${VERSION}" == *"fips"* ]]; then
        OPENSSLDIR=${PREFIX}/etc/openssl/fips
        ENABLE_FIPS="enable-fips"
        cat apps/openssl.cnf | awk "{gsub(/# .include fipsmodule.cnf/,\".include ${OPENSSLDIR}/fipsmodule.cnf\");}1" > apps/openssl.cnf.tmp
        cat apps/openssl.cnf.tmp | awk "{gsub(/# fips = fips_sect/,\"fips = fips_sect\nbase = base_sect\n\n[base_sect]\nactivate = 1\n\");}1" > apps/openssl.cnf
        rm -f apps/openssl.cnf.tmp
    fi
else
    # openssl 1.1.x
    DYLIB_VER="1.1"
    NO_SSL2="no-ssl2"
fi

OS=`uname -s`
case "$OS" in
    Darwin)
        target=darwin64-${ARCH}-cc
        ;;
    Linux)
        target=linux-${ARCH}
        extra_flags=-Wl,--enable-new-dtags,-rpath,\''$$ORIGIN/../lib/'\'
        ;;
    *)
        echo "Unknown platform"
        exit 1
        ;;
esac

./Configure ${target} \
            enable-ec_nistp_64_gcc_128 \
            shared \
            threads \
            no-tests \
            no-ssl \
            ${NO_SSL2} \
            no-ssl3 \
            ${ENABLE_FIPS} \
            --libdir=lib \
            --prefix=${PREFIX} \
            --openssldir=${OPENSSLDIR} \
            ${extra_flags}

# Note - don't use "make -j" as OpenSSL's target dependencies are messed up.
# There's a race which causes frequent build failures.
make && make install DESTDIR=${INSTALL_DIR}

rm -f ${INSTALL_DIR}/${OPENSSLDIR}/*.dist

if [ "$OS" == "Darwin" ]
then
    pushd ${INSTALL_DIR}
    # NOTE: The below loop actually doesn't do anything; the libraries under
    #       lib/engines are actually bundles on macOS and not shared libraries,
    #       so the install_name_tool is a no-op.  Setting the install name
    #       MAY be doable via compile time options, but this would require
    #       further research.  Leaving the code here with a note for possible
    #       future exploration into the issue.
    for lib in $(ls .${PREFIX}/lib/engines*); do
        chmod u+w .${PREFIX}/lib/engines*/${lib}
        install_name_tool -id @rpath/${lib} ./${PREFIX}/lib/engines*/${lib}
        chmod u-w .${PREFIX}/lib/engines*/${lib}
    done

    chmod u+w .${PREFIX}/lib/libssl.${DYLIB_VER}.dylib \
              .${PREFIX}/lib/libcrypto.${DYLIB_VER}.dylib \
              .${PREFIX}/bin/openssl
    install_name_tool -id @rpath/libssl.${DYLIB_VER}.dylib \
                      .${PREFIX}/lib/libssl.${DYLIB_VER}.dylib
    install_name_tool -change ${PREFIX}/lib/libcrypto.${DYLIB_VER}.dylib \
                      @loader_path/libcrypto.${DYLIB_VER}.dylib \
                      .${PREFIX}/lib/libssl.${DYLIB_VER}.dylib
    install_name_tool -id @rpath/libcrypto.${DYLIB_VER}.dylib \
                      .${PREFIX}/lib/libcrypto.${DYLIB_VER}.dylib
    install_name_tool -change ${PREFIX}/lib/libssl.${DYLIB_VER}.dylib \
                      @executable_path/../lib/libssl.${DYLIB_VER}.dylib \
                      -change ${PREFIX}/lib/libcrypto.${DYLIB_VER}.dylib \
                      @executable_path/../lib/libcrypto.${DYLIB_VER}.dylib \
                      .${PREFIX}/bin/openssl
    chmod u-w .${PREFIX}/lib/libssl.${DYLIB_VER}.dylib \
              .${PREFIX}/lib/libcrypto.${DYLIB_VER}.dylib \
              .${PREFIX}/bin/openssl
    popd
fi

# We don't want the entire manual set added to the package
rm -rf ${INSTALL_DIR}/${PREFIX}/man ${INSTALL_DIR}/${PREFIX}/share/doc ${INSTALL_DIR}/${PREFIX}/share/man

# Or pkgconfig files
rm -rf ${INSTALL_DIR}/${PREFIX}/lib/pkgconfig
