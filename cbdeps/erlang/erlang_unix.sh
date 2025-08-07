#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3

JIT_OPTIONS="--enable-jit"

NCURSES_VER=6.4-1
OPENSSL_VER=3.1.8-1

pushd erlang
if [[ "$(cat OTP_VERSION)"  == 24.* && "${PLATFORM}" = "linux" && "$(uname -m)" = "aarch64" ]]; then
    # v24 configure: error: JIT only works on x86 64-bit
    JIT_OPTIONS="--disable-jit"
fi
popd

cd "${ROOT_DIR}"
cbdep --platform ${PLATFORM} install -d cbdeps openssl ${OPENSSL_VER}

cd erlang

case "$PLATFORM" in
    macosx)
        export MACOSX_DEPLOYMENT_TARGET=10.10
        ulimit -u 1024

        # JIT is broken arm64 and causes segfaults under rosetta in
        # v24 and v25, so we explicitly disable it everywhere problems occur
        # (see CBD-4513, CBD-5389)
        JIT_OPTIONS="--disable-jit"
        ;;
    linux)
        # erlang requires libtinfo/terminfo from ncurses
        cbdep --platform ${PLATFORM} install -C -d ${ROOT_DIR}/cbdeps ncurses ${NCURSES_VER}

        # Ensure erl knows where to find the terminfo content
        sed -i "/BINDIR=.*/a export TERMINFO_DIRS=\${ROOTDIR}/../terminfo" erts/etc/unix/erl.src.src

        # We use LDFLAGS to ensure we find libtinfo. We also set two rpaths,
        # this is because we trigger an install script during the server
        # install, and this script copies several binaries into a new
        # location. By providing both rpaths here we avoid the need to modify
        # the rpaths of the binaries post copy.
        LDFLAGS="-L${ROOT_DIR}/cbdeps/ncurses-${NCURSES_VER}/lib -ltinfo "'-Wl,-rpath=\$$\ORIGIN/../..:\$$\ORIGIN/../../..:\$$\ORIGIN/../../../..:\$$\ORIGIN/../../../../..'

        # We need to provide an rpath for the crypto lib
        SSL_RPATH=--with-ssl-rpath="\$$\ORIGIN/../../../../.."

        # During build, erlang's going to create a bootstrap compiler and
        # build some stuff with that, so we need to tell it where to
        # find libtinfo
        export LD_LIBRARY_PATH="${ROOT_DIR}/cbdeps/ncurses-${NCURSES_VER}/lib:$LD_LIBRARY_PATH"
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
      $SSL_RPATH \
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
    # Bundle libtinfo/terminfo
    pushd ${INSTALL_DIR}/lib
    cp -a ${ROOT_DIR}/cbdeps/ncurses-${NCURSES_VER}/lib/libtinfo* .
    cp -aL ${ROOT_DIR}/cbdeps/ncurses-${NCURSES_VER}/lib/terminfo .
    popd
fi

# For whatever reason, the special characters in this filename make
# Jenkins throw a fit (UI warnings about "There are resources Jenkins
# was not able to dispose automatically"), so let's just delete it.
rm -rf lib/ssh/test/ssh_sftp_SUITE_data/sftp_tar_test_data_*
