#!/bin/bash -e

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

source "${WORKDIR}/escrow/patches.sh"

CBDEPS_VERSIONS="@@CBDEPS_VERSIONS@@"

source "${WORKDIR}/escrow/escrow_config" || exit 1

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

heading() {
  echo
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo $*
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo
}

# Global directories
ROOT="${WORKDIR}/escrow"
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

# Populating analytics jars to .cbdepcache
cp -rp /escrow/deps/.cbdepcache/* "${WORKDIR}/.cbdepcache"
cp -rp /escrow/deps/.cbdepscache/* "${WORKDIR}/.cbdepscache"

# Copy of tlm for working in.
if [ ! -d "${TLMDIR}" ]
then
  cp -aL "${ROOT}/src/tlm" "${TLMDIR}" > /dev/null 2>&1 || :
fi

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
  if [ ! -d "${CACHE}/cbdep/${cbdep_ver}/" ]
  then
    echo "Copying"
    mkdir -p "${CACHE}/cbdep/${cbdep_ver}/"
    cp -aL /escrow/deps/cbdep-*-${cbdeps_platform} "${CACHE}/cbdep/${cbdep_ver}/"
    cp -aL /escrow/deps/cbdep-*-${cbdeps_platform} "${CACHE}/cbdep/${cbdep_ver}/"
  fi
done

build_cbdep() {
  dep=$1
  tlmsha=$2
  ver=$3

  if [ -e ${CACHE}/${dep}-${PLATFORM}-*${ver}*.tgz ]
  then
    echo "Dependency ${dep} already built..."
    return
  fi

  heading "Building dependency ${dep}...."

  cd "${TLMDIR}"

  git reset --hard
  git clean -dfx
  git checkout "${tlmsha}"
  patch_tlm_openssl
  patch_curl
  patch_v8

  # Tweak the cbdeps build scripts to "download" the source from our local
  # escrowed copy. Have to re-do this for every dep since we checkout a
  # potentially different SHA each time above.
  shopt -s nullglob
  sed -i.bak \
    -e "s/\(git\|https\):\/\/github.com\/couchbasedeps\/\([^\" ]*\)/file:\/\/\/home\/couchbase\/escrow\/deps\/${dep}/g" \
    ${TLMDIR}/deps/packages/CMakeLists.txt \
    ${TLMDIR}/deps/packages/*/CMakeLists.txt \
    ${TLMDIR}/deps/packages/*/*.sh
  shopt -u nullglob
  # Fix the depot_tools entry
  if [ ${dep} == 'v8' ]; then
     sed -i.bak2 -e 's/file:\/\/\/home\/couchbase\/escrow\/deps\/v8\/depot_tools/file:\/\/\/home\/couchbase\/escrow\/deps\/depot_tools\/depot_tools.git/g' ${TLMDIR}/deps/packages/*/*.sh
  fi

  # skip openjdk-rt cbdeps build
  if [ ${dep} == 'openjdk-rt' ]
  then
    rm -f "${TLMDIR}/deps/packages/openjdk-rt/dl_rt_jar.cmake"
    touch "${TLMDIR}/deps/packages/openjdk-rt/dl_rt_jar.cmake"
  fi

  # Invoke the actual build script
  PACKAGE=${dep} deps/scripts/build-one-cbdep

  echo
  echo "Copying ${dep} to local cbdeps cache..."
  tarball=$( ls ${TLMDIR}/deps/packages/build/deps/${dep}/*/*.tgz )
  cp "${tarball}" "${CACHE}"
  cp "${tarball/tgz/md5}" "${CACHE}/$( basename ${tarball} ).md5"
  rm -rf "${TLMDIR}/deps/packages/build/deps/${dep}"
}

build_cbdep_v2() {
  dep=$1
  ver=$2

  if [ -e ${CACHE}/${dep}*${ver}*.tgz ]
  then
    echo "Dependency ${dep}*${ver}*.tgz already built..."
    return
  fi

  heading "Building dependency v2 ${dep} - ${ver} ...."


  cd "${TLMDIR}"

  rm -rf "${TLMDIR}/deps/packages/${dep}"
  cp -rf "/escrow/deps/${dep}" "${TLMDIR}/deps/packages/"

  pushd "${TLMDIR}/deps/packages/${dep}"

  patch_curl

  export WORKSPACE=`pwd`
  export PRODUCT="${dep}"
  export VERSION="$(echo $ver | awk -F'-' '{print $1}')"
  export BLD_NUM="$(echo $ver | awk -F'-' '{print $2}')"
  export LOCAL_BUILD=true

  build-tools/cbdeps/scripts/build-one-cbdep || exit 1

  echo
  echo "Copying dependency ${dep} to local cbdeps cache..."
  tarball=$( ls ${TLMDIR}/deps/packages/${dep}/*/*/*/*/*.tgz )
  cp ${tarball} ${CACHE}
  cp ${tarball/tgz/md5} ${CACHE}/$( basename ${tarball} ).md5
  rm -rf ${TLMDIR}/deps/packages/${dep}
}

cp -rp /escrow/deps/.cbdepscache/* ${CACHE}

# Build OpenSSL
for dep in $( grep openssl ${ROOT}/deps/dep_manifest_${DOCKER_PLATFORM}.txt )
do
  DEPS=$(echo ${dep} | sed 's/:/ /g')
  heading "Building dependency: ${DEPS}"
  build_cbdep $(echo ${dep} | sed 's/:/ /g')  || exit 1
done

# Build V2 dependencies
for dep in $( cat ${ROOT}/deps/dep_v2_manifest_${DOCKER_PLATFORM}.txt )
do
  DEPS=$(echo ${dep} | sed 's/:/ /')
  heading "Building dependency v2: ${DEPS}"
  build_cbdep_v2 $(echo ${dep} | sed 's/:/ /')  || exit 1
done

# Build remaining dependencies
for dep in $( grep -v openssl ${ROOT}/deps/dep_manifest_${DOCKER_PLATFORM}.txt )
do
  DEPS=$(echo ${dep} | sed 's/:/ /g')
  heading "Building dependency: ${DEPS}"
  build_cbdep $(echo ${dep} | sed 's/:/ /g')  || exit 1
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

