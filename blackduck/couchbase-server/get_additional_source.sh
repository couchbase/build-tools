#!/bin/bash -ex

RELEASE=$1
VERSION=$2
BLD_NUM=$3

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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
  # This will be also be added to PATH by scan-environment.sh in case
  # Detect needs it

  # We need to ask Analytics to build us a BOM, which we then convert
  # to a series of poms that Black Duck can scan. Unfortunately this
  # requires actually building most of Analytics. However, it does
  # allow us to bypass having Detect scan the analytics/ directory.
  pushd "${WORKSPACE}/tempbuild"
  ninja analytics
  popd

  mkdir -p analytics-boms
  "${SCRIPT_DIR}/create-maven-boms" \
    --outdir analytics-boms \
    --file analytics/cbas/cbas-install/target/bom.txt

  # Delete all the built artifacts so BD doesn't scan them
  rm -rf install
}

# Main script starts here - decide which action to take based on VERSION

# Have to run cmake to extract list of GOVERSIONs. Couldn't find a reliable
# way to extract the CMake version from the source (because CMake downloads
# themselves are inconsistent), so just hardcode a recent CMake.
CMAKE_VERSION=3.23.1
NINJA_VERSION=1.10.2
cbdep install -d "${WORKSPACE}/extra" cmake ${CMAKE_VERSION}
cbdep install -d "${WORKSPACE}/extra" ninja ${NINJA_VERSION}
export PATH="${WORKSPACE}/extra/cmake-${CMAKE_VERSION}/bin:${WORKSPACE}/extra/ninja-${NINJA_VERSION}/bin:${PATH}"
export CB_MAVEN_REPO_LOCAL=~/.m2/repository

rm -rf "${WORKSPACE}/tempbuild"
mkdir "${WORKSPACE}/tempbuild"
pushd "${WORKSPACE}/tempbuild"
LANG=en_US.UTF-8 cmake -G Ninja "${WORKSPACE}/src"

YAML="${WORKSPACE}/src/couchbase-server-black-duck-manifest.yaml"
cat <<EOF > "${YAML}"
components:
  go programming language:
    bd-id: 6d055c2b-f7d7-45ab-a6b3-021617efd61b
    versions:
EOF

for gover in $(perl -lne 'm#go-([0-9.]*?)/go# && print $1' build.ninja | sort -u); do
    echo "      - \"${gover}\"" >> "${YAML}"
done

popd

if [ "6.6.5" = $(printf "6.6.5\n${VERSION}" | sort -n | head -1) ]; then
  # 6.6.5 or higher
  create_analytics_poms
else
  download_analytics_jars
fi

# If we find any go.mod files with zero "require" statements, they're probably one
# of the stub go.mod files we introduced to make other Go projects happy. Black Duck
# still wants to run "go mod why" on them, which means they need a full set of
# replace directives.
for stubmod in $(find . -name go.mod \! -execdir grep --quiet require '{}' \; -print); do
    cat ${SCRIPT_DIR}/go-mod-replace.txt >> ${stubmod}
done

# Need to fake the generated go files in indexing, eventing, and eventing-ee
for dir in secondary/protobuf; do
    mkdir -p goproj/src/github.com/couchbase/indexing/${dir}
    touch goproj/src/github.com/couchbase/indexing/${dir}/foo.go
done
for dir in auditevent flatbuf/cfg flatbuf/header flatbuf/payload flatbuf/response parser version; do
    mkdir -p goproj/src/github.com/couchbase/eventing/gen/${dir}
    touch goproj/src/github.com/couchbase/eventing/gen/${dir}/foo.go
done
for dir in gen/nftp/client evaluator/impl/gen/parser evaluator/impl/v8wrapper/process_manager/gen/flatbuf/payload; do
    mkdir -p goproj/src/github.com/couchbase/eventing-ee/${dir}
    touch goproj/src/github.com/couchbase/eventing-ee/${dir}/foo.go
done

# TEMPORARY: If plasma is pointing to the bad SHA, rewind
pushd goproj/src/github.com/couchbase/plasma
if [ $(git rev-parse HEAD) = "627239d4056939f1bcfe92faf9fbf81c9a96537b" ]; then
    git checkout 34d4558a9c2aa34403b0e355cb30120fc919f7e0
fi
popd

# Ensure all go.mod files are fully tidied
cd "${WORKSPACE}/src"
init_checksum=$(repo diff -u | sha256sum)
while true; do
    for gomod in $(find . -name go.mod); do
        pushd $(dirname ${gomod})
        grep --quiet require go.mod || {
            popd
            continue
        }
        go mod tidy
        popd
    done
    curr_checksum=$(repo diff -u | sha256sum)
    if [ "${init_checksum}" = "${curr_checksum}" ]; then
        break
    fi
    echo
    echo "Repo was changed - re-running go mod tidy"
    echo
    init_checksum="${curr_checksum}"
done
