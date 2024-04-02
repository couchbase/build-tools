#!/bin/bash -ex

INSTALL_DIR=$1
ROOT_DIR=$2
PLATFORM=$3

pushd $(dirname $0) > /dev/null
SCRIPTPATH=$(pwd -P)
popd > /dev/null

DEPS=/tmp/deps
rm -rf ${DEPS}
mkdir -p ${DEPS}

# Install ninja if necessary.
if command -v ninja > /dev/null; then
    NINJA=ninja
elif command -v ninja-build > /dev/null; then
    NINJA=ninja-build
else
    cbdep install -d ${DEPS} ninja 1.11.0
    NINJA=${DEPS}/ninja-1.11.0/bin/ninja
fi

# Use gcc10 on Linux, to maintain compatibility with Server 7.2.x.
if [ "${PLATFORM}" = "linux" ]; then
    export PATH=/opt/gcc-10.2.0/bin:$PATH

    if [ "$(uname -m)" = "aarch64" ]; then
        # And for aarch64, build with newest binutils too
        mkdir -p ${DEPS}/binutils

        pushd ${DEPS}/binutils
        BINUTILS_VER=2.42
        curl -Lf https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz -o binutils.tar.xz
        mkdir binutils && cd binutils
        tar xf ../binutils.tar.xz --strip-components=1
        ./configure --prefix=${DEPS}/binutils-${BINUTILS_VER} --enable-gold
        make -j$(nproc)
        make install
        popd

        export PATH=${DEPS}/binutils-${BINUTILS_VER}/bin:$PATH
    fi
fi

#
# Build gn (including platform-specific hacks and patches)
#

# Build gn using the stock compiler on the system. gn will find "clang"
# automatically on Macs; on Linux, it will use CC/CXX.
pushd gn
if [ "${PLATFORM}" = "linux" ]; then
    export CC=gcc
    export CXX=g++
fi

# MB-60408: Newer gn builds set '-std=c++20', but our Mac x86_64
# build agent is running Xcode 12 which doesn't honor that flag.
# Revert to an older SHA which uses c++17.
if [ "${PLATFORM}" = "macosx" -a "$(uname -m)" = "x86_64" ]; then
    git checkout d4be45bb28fbfc16a41a1e02c86137df6815f2dd
fi

python3 build/gen.py
${NINJA} -C out
unset CC CXX
popd
export PATH=$(pwd)/gn/out:$PATH

cd v8

#
# HACKS AND PATCHES for v8 build
#

# icu apparently expects to be built with clang on arm, this flag isn't
# present in gcc
if [ "${PLATFORM}" = "linux" -a "$(uname -m)" = "aarch64" ]; then
    sed -i 's/-mmark-bti-property//g' third_party/icu/BUILD.gn
fi

# Cherry-pick back this fix for arm64 processors, if we don't already have it
if ! git merge-base --is-ancestor 2bb1e2026176 HEAD; then
    git cherry-pick 2bb1e2026176
fi

# This change is required for building on gcc < 13.
# https://groups.google.com/g/v8-reviews/c/mns34cDIvDo
if ! git merge-base --is-ancestor de611e69ad51; then
    git cherry-pick de611e69ad51
fi


V8_ARGS=""

if [ "${PLATFORM}" = "linux" ]; then
    # On Linux, we need to use our stock GCC. Google's clang actually
    # works well (with some coddling) on x86_64, and does a fine job of
    # cross-compiling to aarch64... except that when cross-compiling, it
    # uses the downloaded sysroot's glibc, which is much newer than the
    # one in aarch amzn2. :( So, configure the build to skip everything
    # Google wants us to use.
    V8_ARGS="${V8_ARGS} is_clang=false use_lld=false use_gold=false use_custom_libcxx=false use_glib=false use_sysroot=false"

    if [ "${ARCH}" = "aarch64" ]; then
        # Also, don't let it force weird toolchain-specific names for
        # all the command-line utilities like gcc and readelf.
        sed -ie 's/toolprefix = ".*"/toolprefix = ""/' build/toolchain/linux/BUILD.gn

        # And don't make ld warnings fatal, since the version of
        # binutils we have is too old to understand everything gcc10
        # spits out.
        V8_ARGS="${V8_ARGS} fatal_linker_warnings=false"
    fi

else
    # On Macs, it's easier to just grab Google's clang build and use
    # that.
    python3 tools/clang/scripts/update.py

    # However, the libc++ headers are squirreled away in strange corners
    # of MacOS, and it seems to vary from OS version to OS version. It's
    # also unclear how Google's clang looks for them. Experimentally,
    # though, it appears that *sometimes* they're in the current MacOS
    # SDK, and clang will find them there, so let's see if they exist
    # there.
    if [ ! -d "$(xcrun --show-sdk-path)/usr/include/c++" ]; then
        # Ok, they're NOT there, so Google's clang won't know what to
        # do. Let's see if they're in the CommandLineTools.
        incdir=/Library/Developer/CommandLineTools/usr/include
        if [ -d "${incdir}/c++" ]; then
            # Cool. Inject them in a place that Google's clang happens
            # to want to look.
            pushd third_party/llvm-build/Release+Asserts
            rm -f include
            ln -s "${incdir}"
            popd
        else
            # Out of ideas; run away.
            echo "FATAL: Can't figure out where libc++ headers are!!"
            exit 1
        fi
    fi

    # MB-53924: couchstore map-reduce code uses jemalloc as the
    # default C++ heap allocator, by virtue of linking to
    # couchbase/platform which overrides global operator new/delete to
    # allocate via jemalloc.
    #
    # That requires that the various 'operator new/delete' symbols are
    # weak symbols inside libcouchstore, and all dependencies also
    # have 'operator new/delete' as weak symbols - including V8.
    #
    # This can be examined via the 'nm' command - the operator new /
    # delete symbols in libcouchstore / lib8 should look like:
    #
    #     $ nm -m libv8.dylib | rg __ZdlPv | c++filt
    #                      (undefined) weak external __ZdlPv (from libc++)
    #
    # Note symbol defined as weak:     ^^^^
    #
    # This _should_ be automatic behavior - the libc++-abi headers
    # define the various operator new/delete functions as "default"
    # visibility which means they should be weak when linked into a
    # library.
    #
    # However, if we use lld as the linker for V8, then it *doesn't*
    # mark 'operator new' et al as weak for some unknown reason,
    # resulting in heap mismatches when V8 is used - libv8 itself
    # allocates (and frees) via the system heap, whereas
    # couchstore_views allocates via jemalloc's heap. Given they
    # pass objects between each other this results in various aborts /
    # crashes when trying to free an allocation from a mismatched heap.
    # Fix by disabling lld and using system linker.
    V8_ARGS="use_lld=false"
fi

# One little dropping left over from "gclient sync" that isn't actually
# from git...
touch build/config/gclient_args.gni

# Actual v8 configure and build steps - we build debug and release.
# Ideally this set of args should match the corresponding set in
# v8_windows.bat.

V8_ARGS="${V8_ARGS} v8_enable_webassembly=false use_custom_libcxx=false is_component_build=true v8_enable_backtrace=true v8_use_external_startup_data=false v8_enable_pointer_compression=false treat_warnings_as_errors=false icu_use_data_file=false"

gn gen out/release --args="$V8_ARGS is_debug=false dcheck_always_on=false"
${NINJA} -j4 -C out/release v8

gn gen out/debug --args="$V8_ARGS is_debug=true v8_optimized_debug=true symbol_level=1 v8_enable_slow_dchecks=true"
${NINJA} -j4 -C out/debug v8

# Copy right stuff to output directory.
mkdir -p \
    $INSTALL_DIR/lib/Release \
    $INSTALL_DIR/lib/Debug \
    $INSTALL_DIR/include/libplatform \
    $INSTALL_DIR/include/cppgc \
    $INSTALL_DIR/include/unicode
(
    cd out/release
    rm *.TOC
    cp -avi libv8*.* $INSTALL_DIR/lib/Release
    cp -avi libchrome*.* $INSTALL_DIR/lib/Release
    cp -avi libicu*.* $INSTALL_DIR/lib/Release
    cp -avi libthi*.* $INSTALL_DIR/lib/Release
)
(
    cd out/debug
    rm *.TOC
    cp -avi libv8*.* $INSTALL_DIR/lib/Debug
    cp -avi libchrome*.* $INSTALL_DIR/lib/Debug
    cp -avi libicu*.* $INSTALL_DIR/lib/Debug
    cp -avi libthi*.* $INSTALL_DIR/lib/Debug
)
(
    cd include
    cp -avi v8*.h $INSTALL_DIR/include
    cp -avi libplatform/[a-z]*.h $INSTALL_DIR/include/libplatform
    cp -avi cppgc/[a-z]* $INSTALL_DIR/include/cppgc
)
(
    cd third_party/icu/source/common/unicode
    cp -avi *.h $INSTALL_DIR/include/unicode
)
(
    cd third_party/icu/source/io/unicode
    cp -avi *.h $INSTALL_DIR/include/unicode
)
(
    cd third_party/icu/source/i18n/unicode
    cp -avi *.h $INSTALL_DIR/include/unicode
)
(
    cd third_party/icu/source/extra/uconv/unicode
    cp -avi *.h $INSTALL_DIR/include/unicode
)
