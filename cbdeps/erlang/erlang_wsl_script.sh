INSTALL_DIR=$(wslpath "$1")

# Expects to be called in the directory containing this script,
# which is three levels deep in build-tools
cd ../../..
OPENSSL_DIR=$(echo $(pwd)/cbdeps/openssl-*)

# Now into the OTP source code
cd erlang

# build the source, as per instructions
eval $(./otp_build env_win32 x64)
./otp_build configure \
      --without-javac \
      --without-et \
      --without-debugger \
      --without-megaco \
      --with-ssl=${OPENSSL_DIR} 2>&1 | tee configure.out
./otp_build boot -a 2>&1 | tee boot.out
./otp_build release -a "${INSTALL_DIR}" 2>&1 | tee release.out
