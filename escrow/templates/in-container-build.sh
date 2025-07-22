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
if [ ! -e /home/couchbase/escrow ]
then
  echo "This script is intended to be run inside a specifically-configured "
  echo "Docker container. See build-couchbase-server-from-escrow.sh."
  exit 100
fi

WORKDIR=$1
PLATFORM=$2
SERVER_VERSION=$3

CBDEP_VERSIONS="@@CBDEP_VERSIONS@@"

source "${WORKDIR}/escrow/escrow_config"

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

# Create all cbdeps. Start with the cache directory.
mkdir -p "${CACHE}"
mkdir -p "${WORKDIR}/.cbdepcache"

(
  cd ${WORKDIR}/.cbdepscache/
  for package in cbas-jars-all-noarch-*.tgz
  do
    ver_build=$(echo $package | sed -e 's/cbas-jars-all-noarch-//' -e 's/\.tgz//')
    version=$(echo $ver_build | sed 's/-.*//')
    build=$(echo $ver_build | sed 's/.*-//')
    ${WORKDIR}/deps/cbdep-1.2.0-linux-$(uname -m) install analytics-jars ${version}-${build} --cache-local-file cbas-jars-all-noarch-${version}-${build}.tgz
  done
)

# Pre-populate cbdeps
heading "Populating ${PLATFORM} cbdeps... (${CBDEP_VERSIONS})"

case "${PLATFORM}" in
  mac*) cbdeps_platform='macos' ;;
  win*) cbdeps_platform='window';;
     *) cbdeps_platform='linux' ;;
esac
for cbdep_ver in ${CBDEP_VERSIONS}
do
  echo "Checking ${cbdep_ver}"
  if [ ! -d "${CACHE}/cbdep/${cbdep_ver}/" -o ! -f "${CACHE}/cbdep/${cbdep_ver}/cbdep-${cbdep_ver}-${cbdeps_platform}" ]
  then
    echo "Copying"
    mkdir -p "${CACHE}/cbdep/${cbdep_ver}/"
    cp -aL ${WORKDIR}/deps/cbdep-${cbdep_ver}-${cbdeps_platform}* "${CACHE}/cbdep/${cbdep_ver}/"
  fi
done

# Copy in all Go versions.
heading "Copying Golang versions..."
if [ -d "${ROOT}/golang" ] && [ "$(ls -A ${ROOT}/golang 2>/dev/null)" ]; then
  cp -a ${ROOT}/golang/* ${CACHE}
else
  echo "FATAL: No Go versions found in ${ROOT}/golang/"
  echo "The build requires Go compilers to be available. This indicates the escrow preparation failed."
  exit 1
fi

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

