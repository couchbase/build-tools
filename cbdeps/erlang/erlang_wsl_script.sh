INSTALL_DIR=$(wslpath "$1")

set -e
set -o pipefail

# Expects to be called in the directory containing this script,
# which is three levels deep in build-tools
cd ../../..
source build-tools/utilities/shell-utils.sh

OPENSSL_VER=$(annot_from_manifest OPENSSL_VERSION)
cbdep.exe -p windows install -d cbdeps openssl ${OPENSSL_VER}
OPENSSL_DIR=$(echo "$(pwd)/cbdeps/openssl-"*)

# Windows build doesn't use ncurses

# Now into the OTP source code
cd erlang

# Fix line endings - when extracted on Windows, scripts may have CRLF
# but WSL bash needs LF. Convert shell scripts and autoconf files recursively.
echo "Converting line endings for shell scripts..."
# Be specific about autoconf files to avoid breaking other .in files
find . -type f \( \
    -name "*.sh" \
    -o -name "otp_build" \
    -o -name "configure" \
    -o -name "config.guess" \
    -o -name "config.sub" \
    -o -name "install-sh" \
    -o -name "install.sh" \
\) -exec sed -i 's/\r$//' {} \;

# build the source, as per instructions
# Set up cross-compilation environment manually. We can't use 'otp_build env_win32'
# because it corrupts backslashes in INCLUDE/LIB/LIBPATH when echoing them.
# The VS paths are already set via WSLENV from Windows.
export ERL_TOP="$PWD"
export OVERRIDE_TARGET="win32"
export CONFIG_SUBTYPE="win64"
export WSLcross="true"

# Patch make_version to not transform "win32" architecture for 64-bit builds.
# OTP 28+ added logic that changes "win32" -> "x86_64-pc-windows" when CONFIG_SUBTYPE="win64",
# but this breaks the rebar3 pc plugin's platform detection (it expects "win32" pattern).
# We need CONFIG_SUBTYPE for 64-bit compiler flags, but we need to preserve the architecture.
MAKE_VERSION_FILE="erts/emulator/utils/make_version"
if grep -q 'x86_64-pc-windows' "$MAKE_VERSION_FILE"; then
    echo "Patching make_version to preserve win32 architecture for x64 builds..."
    # Comment out just the win64 architecture transformation line
    sed -i 's|\$architecture = "x86_64-pc-windows";|# PATCHED: keep win32 for rebar3 pc plugin compatibility|' "$MAKE_VERSION_FILE"
fi
export CC="cc.sh"
export CXX="cc.sh"
export AR="ar.sh"
export RANLIB="true"
export OVERRIDE_CONFIG_CACHE_STATIC="$ERL_TOP/make/autoconf/win64.config.cache.static"
export OVERRIDE_CONFIG_CACHE="$ERL_TOP/make/autoconf/win64.config.cache"
export WIN32_WRAPPER_PATH="$ERL_TOP/erts/etc/win32/wsl_tools/vc:$ERL_TOP/erts/etc/win32/wsl_tools"
export PATH="$WIN32_WRAPPER_PATH:$PATH"
export VCToolsRedistDir=""
# Build WSLPATH from Windows paths in PATH (for wrapper scripts that need it)
export WSLPATH=$(echo "$PATH" | tr ':' '\n' | grep '^/mnt/c/' | tr '\n' ':' | sed 's/:$//')
# INCLUDE, LIB, LIBPATH are already set correctly via WSLENV from Windows
./otp_build configure \
      --without-javac \
      --without-et \
      --without-debugger \
      --without-megaco \
      --with-ssl=${OPENSSL_DIR} 2>&1 | tee configure.out
./otp_build boot -a 2>&1 | tee boot.out
./otp_build release -a "${INSTALL_DIR}" 2>&1 | tee release.out
