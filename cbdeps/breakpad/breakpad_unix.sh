#!/bin/bash -e
#
# NOTE: Currently building on macOS is not supported

INSTALL_DIR=$1
ROOT_DIR=$2

# Ensure depot_tools is present and pathed
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
pushd depot_tools && git checkout df336feec9a9f43a9239634e763cc7530f5216ca && popd
export PATH=$(pwd)/depot_tools:$PATH

# Prevent depot_tools autoupdates
export DEPOT_TOOLS_UPDATE=0

# Install python modules required for build
python3 -m venv env
source env/bin/activate
pip3 install httplib2 six 2to3

pushd breakpad
  2to3 src/tools/python/deps-to-manifest.py -w
  if [ "$(uname -m)" = "aarch64" ]; then
    # Breakpad doesn't build correctly on arm with glibc2.17, which
    # is what we have currently in the single-linux worker. We need
    # to tweak some structs to fix it
    patch -p1 <"${ROOT_DIR}/build-tools/cbdeps/breakpad/patches/0001-Fix-glibc2.17-arm-build.patch"
  fi
  # gclient sync expects an upstream remote called 'origin' but after a sync
  # we end up with a mix of remotes - either 'google,' 'googlesource,' 'origin'
  # or a combination of google.* + origin. So we need to prune this down to
  # just origin
  for subdir in testing third_party/lss third_party/protobuf/protobuf tools/gyp; do
    pushd src/${subdir}
      googleremote=$(git remote -v | awk '{print $1}' | grep google | head -n1)
      if [ "${googleremote}" != "" ]; then
        if git remote -v | awk '{print $1}' | grep -q origin; then
          git remote remove origin
        fi
        git remote rename ${googleremote} origin
      fi
    popd
  done
popd

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
