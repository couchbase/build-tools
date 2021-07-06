#!/bin/bash -e
#
# NOTE: Currently building on macOS is not supported

INSTALL_DIR=$1
ROOT_DIR=$2

# Ensure depot_tools is present and pathed
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
pushd depot_tools && git checkout df336feec9a9f43a9239634e763cc7530f5216ca && popd
export PATH=$(pwd)/depot_tools:$PATH

# gclient sync expects the breakpad source to live in src
mv breakpad src

# Set up gclient config for tag to pull for breakpad, then do sync
# (this handles the 'fetch breakpad' done by the usual process)
cat > .gclient <<EOF
solutions = [
  {
    "url": "https://github.com/couchbasedeps/google-breakpad.git@couchbase-20200430",
    "managed": False,
    "name": "breakpad",
    "deps_file": "DEPS",
  },
];
EOF

export VPYTHON_BYPASS="manually managed python not supported by chrome operations"
gclient sync

export LDFLAGS="-Wl,-rpath,'\$\$ORIGIN/../lib'"

cd src
./configure --prefix=${INSTALL_DIR}
make
make install
