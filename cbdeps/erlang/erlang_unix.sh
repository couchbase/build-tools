#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3

JIT_OPTIONS="--enable-jit"

pushd erlang
if [ "25" = $(printf "25\n$(cat OTP_VERSION)" | sort -n | head -1) ]; then
    OPENSSL_VER=3.0.7-2
else
    if [ "${PLATFORM}" = "linux" -a "$(uname -m)" = "aarch64" ]; then
        # v24 configure: error: JIT only works on x86 64-bit
        JIT_OPTIONS="--disable-jit"
    fi
    OPENSSL_VER=1.1.1p-1
fi
popd

CBPY_VER=7.2.0-cb1

cd "${ROOT_DIR}"
cbdep --platform ${PLATFORM} install -d cbdeps openssl ${OPENSSL_VER}

cd erlang

case "$PLATFORM" in
    macosx)
        export MACOSX_DEPLOYMENT_TARGET=10.10
        ulimit -u 1024

        # JIT is broken in v24 on arm and causes segfaults under rosetta in
        # v24 and v25, so we explicitly disable it everywhere problems occur
        # (see CBD-4513)
        JIT_OPTIONS="--disable-jit"
        if [ "25" = $(printf "25\n$(cat OTP_VERSION)" | sort -n | head -1) ]; then
            if [ "$(arch)" = "arm64" ]; then
                # JIT's ok on arm in v25+, so we can enable it there
                JIT_OPTIONS="--enable-jit"
            fi
        fi
        ;;
    *)
        # We'll be using libtinfo.so.6 from cbpy since it's being built
        # into couchbase-server already - some old distros come with
        # ncurses5, some new ones come only with ncurses 6. By using
        # cbpy's version we don't need to worry about any of that.
        rm -rf ../cbdeps/cbpy
        mkdir -p ../cbdeps/cbpy
        pushd ../cbdeps/cbpy
        curl -LO https://packages.couchbase.com/couchbase-server/deps/cbpy/${CBPY_VER}/cbpy-${PLATFORM}-$(uname -m)-${CBPY_VER}.tgz
        tar xf cbpy*  --wildcards "*tinfo*"
        popd

        # We use LDFLAGS to ensure we find the libtinfo from cbpy
        LDFLAGS="-L${ROOT_DIR}/cbdeps/cbpy/lib -ltinfo"

        # During build, erlang's going to create a bootstrap compiler and
        # build some stuff with that, so we need to tell it where to
        # find our cbpy libtinfo
        export LD_LIBRARY_PATH="${ROOT_DIR}/cbdeps/cbpy/lib:$LD_LIBRARY_PATH"
        ;;
esac

LDFLAGS=$LDFLAGS ./configure --prefix="$INSTALL_DIR" \
      --enable-smp-support \
      --disable-hipe \
      --disable-fp-exceptions \
      --without-javac \
      --without-et \
      --without-debugger \
      --without-megaco \
      --with-ssl="${ROOT_DIR}/cbdeps/openssl-${OPENSSL_VER}" \
      $JIT_OPTIONS \
      CFLAGS="-fno-strict-aliasing -O3 -ggdb3"

make -j4
make install

# Prune wxWidgets - we needed this available for building observer
# but not needed at runtime
rm -rf ${INSTALL_DIR}/lib/erlang/lib/wx-*

# Set rpaths
ERTS_DIR=$(echo ${INSTALL_DIR}/lib/erlang/erts-*)
# On MacOS, set up the RPath for the crypto plugin to find our custom OpenSSL
if [ "${PLATFORM}" = "macosx" ]; then
    CRYPTO_DIR=$(echo ${INSTALL_DIR}/lib/erlang/lib/crypto-*)
    install_name_tool -add_rpath @loader_path/../../../../.. \
        ${CRYPTO_DIR}/priv/lib/crypto.so
    install_name_tool -add_rpath @loader_path/../../.. \
        ${ERTS_DIR}/bin/beam.smp
elif [ "${PLATFORM}" = "linux" ]; then
    # We need to set rpaths on various binaries so they can find libs
    # in /opt/couchbase/lib (or equivalent relative location)
    for f in $(find ${INSTALL_DIR} -type f); do
        if file $f | grep -q ELF && readelf -d $f | grep -e "tinfo\|crypto" -q; then
            patchelf --set-rpath '$ORIGIN/'$(realpath --relative-to $(dirname $f) ${INSTALL_DIR}/lib) $f
        fi
    done

    # We bundle the final libtinfo symlinks here (although the target won't
    # actually exist until cbpy is present in the build)
    pushd ${INSTALL_DIR}/lib
    ln -s ./python/interp/lib/libtinfo.so.6 libtinfo.so
    ln -s ./python/interp/lib/libtinfo.so.6 libtinfo.so.6
    ln -s ./python/interp/lib/libtinfo.so.6 libtinfo.so.6.3
    popd
fi

# For whatever reason, the special characters in this filename make
# Jenkins throw a fit (UI warnings about "There are resources Jenkins
# was not able to dispose automatically"), so let's just delete it.
rm -rf lib/ssh/test/ssh_sftp_SUITE_data/sftp_tar_test_data_*
