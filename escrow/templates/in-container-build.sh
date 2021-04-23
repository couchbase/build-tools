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

source "${WORKDIR}/escrow/patches.sh"

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

# Populating caches to working cache dir
cp -rp /escrow/deps/.cbdepcache/* "${WORKDIR}/.cbdepcache"
cp -rp /escrow/deps/.cbdepscache/* "${WORKDIR}/.cbdepscache"

(
  cd /escrow/deps/.cbdepscache/
  for package in analytics*
  do
    ver_build=$(echo $package | sed -e 's/analytics-jars-//' -e 's/\.tar\.gz//')
    version=$(echo $ver_build | sed 's/-.*//')
    build=$(echo $ver_build | sed 's/.*-//')
    /escrow/deps/cbdep-0.9.17-linux install analytics-jars ${version}-${build} --cache-local-file analytics-jars-${version}-${build}.tar.gz
  done
)

# Copy of tlm for working in.
if [ ! -d "${TLMDIR}" ]
then
  cp -aL "${ROOT}/src/tlm" "${TLMDIR}" > /dev/null 2>&1 || :
fi

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
  patch_curl
  patch_tlm_folly
  patch_tlm_openssl
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

  # Invoke the actual build script
  PACKAGE=${dep} deps/scripts/build-one-cbdep

  echo
  echo "Copying ${dep} to local cbdeps cache..."
  tarball=$( ls ${TLMDIR}/deps/packages/build/deps/${dep}/*/*.tgz )
  cp "${tarball}" "${CACHE}"
  cp "${tarball/tgz/md5}" "${CACHE}/$( basename ${tarball/tgz/md5} )"
  cp "${tarball/tgz/md5}" "${CACHE}/$( basename ${tarball/tgz/tgz.md5} )"
  rm -rf "${TLMDIR}/deps/packages/build/deps/${dep}"
  patch_suse15_deps
}

build_cbdep_v2() {
  dep=$1
  ver=$2

  if [ -e "${CACHE}/${dep}-${PLATFORM}-"*"${ver}"*".tgz" ]
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
  export PROFILE=server
  export PACKAGE=$1
  export RELEASE

  # RELEASE is set in escrow_config to e.g. cheshire-cat, while
  # build-one-cbdep expects a RELEASE env var to be set which
  # should = VERSION
  _RELEASE="${RELEASE}"
  RELEASE="${VERSION}"
  build-tools/cbdeps/scripts/build-one-cbdep
  RELEASE="${_RELEASE}"

  echo
  echo "Copying dependency ${dep} to local cbdeps cache..."
  tarball=$( ls ${TLMDIR}/deps/packages/${dep}/*/*/*/*/*.tgz )
  cp ${tarball} ${CACHE}
  cp "${tarball/tgz/md5}" "${CACHE}/$( basename ${tarball/tgz/md5} )"
  cp "${tarball/tgz/md5}" "${CACHE}/$( basename ${tarball/tgz/tgz.md5} )"
  rm -rf ${TLMDIR}/deps/packages/${dep}
  patch_suse15_deps
}

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

cp -rp /escrow/deps/.cbdepscache/* ${CACHE}

patch_md5s

# Build OpenSSL
for dep in $( grep openssl ${ROOT}/deps/dep_manifest_${DOCKER_PLATFORM}.txt )
do
  DEPS=$(echo ${dep} | sed 's/:/ /g')
  heading "Building dependency: ${DEPS}"
  build_cbdep $(echo ${dep} | sed 's/:/ /g')
done

# Build V2 dependencies
for dep in $( cat ${ROOT}/deps/dep_v2_manifest_${DOCKER_PLATFORM}.txt )
do
  DEPS=$(echo ${dep} | sed 's/:/ /')
  build_cbdep_v2 $(echo ${dep} | sed 's/:/ /')
done

# Build remaining dependencies
for dep in $( grep -v openssl ${ROOT}/deps/dep_manifest_${DOCKER_PLATFORM}.txt )
do
  DEPS=$(echo ${dep} | sed 's/:/ /g')
  heading "Building dependency: ${DEPS}"
  build_cbdep $(echo ${dep} | sed 's/:/ /g')
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

