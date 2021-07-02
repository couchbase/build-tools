#!/bin/bash
set -e

# Ensure repo launcher is up to date
(
  cd $(dirname $(which repo))
  sudo curl -fLO https://storage.googleapis.com/git-repo-downloads/repo
  sudo chmod a+x ./repo
)

# Ensure python3 is pathed and available
export PATH=$PATH:/home/couchbase/escrow/src/server_build/tlm/python/miniconda3-4.6.14/bin
if [ -f /usr/bin/python3 ]; then
  if [ -f /home/couchbase/escrow/src/server_build/tlm/python/miniconda3-4.6.14/bin/python3 ]; then
    sudo rm -rf /usr/bin/python3
    sudo ln -s /home/couchbase/escrow/src/server_build/tlm/python/miniconda3-4.6.14/bin/python3 /usr/bin/python3
  fi
fi

# Ensure /usr/bin/python is python2
sudo rm -rf $(which python)
sudo ln -s $(which python2) /usr/bin/python

# Error-check. This directory should exist due to the "docker run" mount.
if [ ! -e /escrow ]
then
  echo "This script is intended to be run inside a specifically-configured "
  echo "Docker container. See build-couchbase-server-from-escrow.sh."
  exit 100
fi

WORKDIR=$1
DOCKER_PLATFORM=$2
SERVER_VERSION=$3

CBDEPS_VERSIONS="@@CBDEPS_VERSIONS@@"

source "${WORKDIR}/escrow/escrow_config"

# Convert Docker platform to Build platform (sorry they're different)
if [ "${DOCKER_PLATFORM}" = "ubuntu18" ]
then
  PLATFORM=ubuntu18.04
elif [ "${DOCKER_PLATFORM}" = "ubuntu16" ]
then
  PLATFORM=ubuntu16.04
else
  PLATFORM="${DOCKER_PLATFORM}"
fi

export PLATFORM

heading() {
  echo
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo $*
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo
}

# Global directories
export ROOT="${WORKDIR}/escrow"
CACHE="${WORKDIR}/.cbdepscache"
TLMDIR="${WORKDIR}/tlm"

# Not sure why this is necessary, but it is for v8
if [ "${PLATFORM}" = "ubuntu16.04" ]
then
  heading "Installing pkg-config..."
  sudo apt-get update && sudo apt-get install -y pkg-config
fi

# Create all cbdeps. Start with the cache directory.
mkdir -p "${CACHE}"
mkdir -p "${WORKDIR}/.cbdepcache"

(
  cd /escrow/.cbdepscache/
  for package in analytics*
  do
    ver_build=$(echo $package | sed -e 's/analytics-jars-//' -e 's/\.tar\.gz//')
    version=$(echo $ver_build | sed 's/-.*//')
    build=$(echo $ver_build | sed 's/.*-//')
    /escrow/deps/cbdep-0.9.18-linux install analytics-jars ${version}-${build} --cache-local-file analytics-jars-${version}-${build}.tar.gz
  done
)

# Pre-populate cbdeps
heading "Populating ${PLATFORM} cbdeps... (${CBDEPS_VERSIONS})"

case "${PLATFORM}" in
  mac*) cbdeps_platform='macos' ;;
  win*) cbdeps_platform='window';;
     *) cbdeps_platform='linux' ;;
esac
for cbdep_ver in ${CBDEPS_VERSIONS}
do
  echo "Checking ${cbdep_ver}"
  if [ ! -d "${CACHE}/cbdep/${cbdep_ver}/" -o ! -f "${CACHE}/cbdep/${cbdep_ver}/cbdep-${cbdep_ver}-${cbdeps_platform}" ]
  then
    echo "Copying"
    mkdir -p "${CACHE}/cbdep/${cbdep_ver}/"
    cp -aL /escrow/deps/cbdep-${cbdep_ver}-${cbdeps_platform} "${CACHE}/cbdep/${cbdep_ver}/"
    cp -aL /escrow/deps/cbdep-${cbdep_ver}-${cbdeps_platform} "${CACHE}/cbdep/${cbdep_ver}/"
  fi
done

# Copy in all Go versions.
heading "Copying Golang versions..."
cp -a ${ROOT}/golang/* ${CACHE}

# Need to unset variables from cbdeps V2 build
  unset WORKSPACE
  unset PRODUCT
  unset VERSION
  unset BLD_NUM
  unset LOCAL_BUILD

# Finally, build the Couchbase Server package.
heading "Building Couchbase Server ${VERSION} Enterprise Edition..."
${ROOT}/src/cbbuild/scripts/jenkins/couchbase_server/server-linux-build.sh \
  ${PLATFORM} ${SERVER_VERSION} enterprise 9999

# Remove any "oel7" binaries to avoid confusion
rm -f ${ROOT}/src/couchbase*oel7*rpm

