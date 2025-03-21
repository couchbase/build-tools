#!/bin/bash -ex

RELEASE=$1
VERSION=$2
BLD_NUM=$3

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR="${WORKSPACE}/tempbuild"

NODEJS_VERSION=16.20.2

download_analytics_jars() {
  mkdir -p thirdparty-jars

  # Determine old version builds
  for version in $(
    perl -lne '/SET \(bc_build_[^ ]* "(.*)"\)/ && print $1' analytics/CMakeLists.txt
  ); do

    cbdep install -d thirdparty-jars analytics-jars ${version}

  done
}

create_analytics_poms() {
  # We need to ask Analytics to build us a BOM, which we then convert
  # to a series of poms that Black Duck can scan. Unfortunately this
  # requires actually building most of Analytics. However, it does
  # allow us to bypass having Detect scan the analytics/ directory.
  pushd "${BUILD_DIR}"
  ninja analytics
  popd

  mkdir -p analytics-boms
  uv run --project "${SCRIPT_DIR}/../scripts" --quiet \
    "${SCRIPT_DIR}/../scripts/create-maven-boms.py" \
      --outdir analytics-boms \
      --file analytics/cbas/cbas-install/target/bom.txt
}

# Main script starts here - decide which action to take based on VERSION

# Have to configure the Server build for several reasons. Couldn't find
# a reliable way to extract the CMake version from the source (because
# CMake downloads themselves are inconsistent), so just hardcode a
# recent CMake.
CMAKE_VERSION=3.29.6
NINJA_VERSION=1.10.2
cbdep install -d "${WORKSPACE}/extra" cmake ${CMAKE_VERSION}
cbdep install -d "${WORKSPACE}/extra" ninja ${NINJA_VERSION}
export PATH="${BUILD_DIR}/tlm/deps/maven.exploded/bin:${WORKSPACE}/extra/cmake-${CMAKE_VERSION}/bin:${WORKSPACE}/extra/ninja-${NINJA_VERSION}/bin:${PATH}"
export CB_MAVEN_REPO_LOCAL=~/.m2/repository

rm -rf "${BUILD_DIR}"
mkdir "${BUILD_DIR}"
pushd "${BUILD_DIR}"
LANG=en_US.UTF-8 cmake -G Ninja "${WORKSPACE}/src" -DBUILD_COLUMNAR=true -DBUILD_ENTERPRISE=true

# Most cbdeps packages that have embedded black-duck-manifest.yaml files will
# be under ${BUILD_DIR} and so will get picked up automatically. However, cbpy
# gets unpacked into the install directory, which we will shortly delete. Copy
# that file into ${BUILD_DIR} to keep it safe, if it exists.
CBPY_MANIFEST="${WORKSPACE}/src/install/lib/python/interp/cbpy-black-duck-manifest.yaml"
if [ -e "${CBPY_MANIFEST}" ]; then
  cp "${CBPY_MANIFEST}" .
fi

# Newer cbpy packages have a locked requirements.txt file that Black
# Duck can parse directly. If that exists, copy it to the source
# directory. Either way, ensure no other requirements.txt files are
# present.
find "${WORKSPACE}" -type f -name requirements.txt -delete
CBPY_REQS="${WORKSPACE}/src/install/lib/python/interp/lib/cb-requirements.txt"
if [ -e "${CBPY_REQS}" ]; then
  cp "${CBPY_REQS}" "${WORKSPACE}/src/requirements.txt"
else
  # If there's no locked requirements.txt, we need to create one
  # or else Detect complains
  touch "${WORKSPACE}/src/requirements.txt"
fi

# Extract the set of Go versions from the build.
GO_MANIFEST="${WORKSPACE}/src/couchbase-columnar-black-duck-manifest.yaml"
GOVER_FILE=$(ls tlm/couchbase-server-*-go-versions.yaml)
uv run --project "${SCRIPT_DIR}/../scripts" --quiet \
  "${SCRIPT_DIR}/../scripts/build-go-manifest.py" \
    --go-versions "${GOVER_FILE}" \
    --output "${GO_MANIFEST}" \
    --max-ver-file max-go-ver.txt

# Also install the maximum Golang version and put it on PATH for later
GOMAX=$(cat max-go-ver.txt)
cbdep install -d "${WORKSPACE}/extra" golang ${GOMAX}
export PATH="${WORKSPACE}/extra/go${GOMAX}/bin:${PATH}"

popd

create_analytics_poms

# Black Duck does a number of "go" operations directly, which requires
# that all packages are fully tidied. This is easier in Doric and later
# releases, so we do it here. For earlier releases, the older logic has
# been split into a separate script
if [ "1.2.0" = $(printf "1.2.0\n${VERSION}" | sort -n | head -1) ]; then
  # Doric or higher
  pushd "${BUILD_DIR}"
  ninja go-mod-tidy-all
  popd
else
  pushd "${WORKSPACE}/src"
  "${SCRIPT_DIR}/go_mod_tidy_pre_doric.sh"
  popd
fi

# TEMPORARY: If plasma is pointing to the bad SHA, rewind
# plasma doesn't exist after columnar 1.2.0
if [[ -d goproj/src/github.com/couchbase/plasma ]]; then
    pushd goproj/src/github.com/couchbase/plasma
    if [ $(git rev-parse HEAD) = "627239d4056939f1bcfe92faf9fbf81c9a96537b" ]; then
        git checkout 34d4558a9c2aa34403b0e355cb30120fc919f7e0
    fi
    popd
fi

# package-lock.json from an old version of npm, need to regenerate
cbdep install -d .deps nodejs ${NODEJS_VERSION}
export PATH=$(pwd)/.deps/nodejs-${NODEJS_VERSION}/bin:$PATH

# angular-bootstrap exists before columnar 1.2.0.
if [[ -d cbgt/rest/static/lib/angular-bootstrap ]]; then
    pushd cbgt/rest/static/lib/angular-bootstrap
    npm install --legacy-peer-deps
    popd
fi
rm -rf .deps/nodejs-${NODEJS_VERSION}

# Delete all the built artifacts so BD doesn't scan them. Do this last
# as some of the earlier steps may depend on things in the install
# directory, eg. python.
rm -rf install
