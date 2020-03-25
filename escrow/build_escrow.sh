#!/bin/bash -e

source ./escrow_config || exit 1

# Top-level directory; everything to escrow goes in here.
if [ -z "$1" ]
then
  echo "Usage: $0 /path/to/output/files"
  exit 1
fi

# Make sure we're using an absolute path
pushd $1
ROOT=$(pwd)
popd

# Compute list of platforms from Docker image names
# (will need to change this algorithm if we change the
# Docker image naming convention)
PLATFORMS=$(
  perl -e 'print join(" ", map { m@couchbasebuild/server-(.*)-build@ && $1} @ARGV)' ${IMAGES}
)

# Functions
fatal() {
  echo "FATAL: $@"
  exit 1
}

get_cbdep_git() {
  local dep=$1

  cd "${ESCROW}/deps"
  if [ ! -d "${dep}" ]
  then
    heading "Downloading cbdep ${dep} ..."
    # This special approach ensures all remote branches are brought
    # down as well, which ensures in-container-build.sh can also check
    # them out. See https://stackoverflow.com/a/37346281/1425601 .
    mkdir "${dep}"
    cd "${dep}"
    if [ ! -d .git ]
    then
      git clone --bare "git://github.com/couchbasedeps/${dep}.git" .git
    fi
    git config core.bare false
    git checkout
  fi
}

get_build_manifests_repo() {
  heading "Downloading build-manifests ..."
  cd "${ESCROW}"

  if [ ! -d build-manifests ]
  then
    git clone git://github.com/couchbase/build-manifests.git
  else
    (cd build-manifests && git fetch origin master)
  fi
}

get_cbdeps2_src() {
  local dep=$1
  local ver=$2
  local manifest=$3
  local sha=$4

  cd "${ESCROW}/deps"

    mkdir "${dep}" || :
    cd "${dep}"
    heading "Downloading cbdep2 ${manifest} at ${sha} ..."
    repo init -u git://github.com/couchbase/build-manifests -g all -m "cbdeps/${manifest}" -b "${sha}"
    repo sync --jobs=6
}

download_cbdep() {
  local dep=$1
  local ver=$2
  local dep_manifest=$3
  heading "download_cbdep - $dep $ver $dep_manifest"

  # skip openjdk-rt cbdeps build
  if [[ ${dep} == 'openjdk-rt' ]]
  then
    :
  else
    get_cbdep_git "${dep}"
  fi

  # Split off the "version" and "build number"
  version=$(echo "${ver}" | perl -nle '/^(.*?)(-cb.*)?$/ && print $1')
  cbnum=$(echo "${ver}" | perl -nle '/-cb(.*)/ && print $1')

  # Figure out the tlm SHA which builds this dep
  tlmsha=$(
    cd "${ESCROW}/src/tlm" &&
    git grep -c "_ADD_DEP_PACKAGE(${dep} ${version} .* ${cbnum})" \
      $(git rev-list --all -- deps/packages/CMakeLists.txt) \
      -- deps/packages/CMakeLists.txt \
    | awk -F: '{ print $1 }' | head -1
  )
  if [ -z "${tlmsha}" ]; then
    echo "ERROR: couldn't find tlm SHA for ${dep} ${version} @${cbnum}@"
    exit 1
  fi
  echo "${dep}:${tlmsha}:${ver}" >> "${dep_manifest}"
}

cache_deps() {
  # Retrieves versions from tlm/deps/manifest.cmake and pulls each
  # package in CACHED_DEPS (escrow_config.sh) to .cbdepscache
  echo "# Patch: Caching deps"

  local cache=${ESCROW}/deps/.cbdepscache
  mkdir -p $cache || :

  for platform in ${PLATFORMS}
  do
    echo "platform: ${platform}"
    for dependency in ${CACHED_DEPS[@]}
    do
      if [ "${platform}" = "ubuntu18" ]
      then
        platform="ubuntu18.04"
      elif [ "${platform}" = "ubuntu16" ]
      then
        platform="ubuntu16.04"
      fi
      local version=$(awk "/$dependency .*${platform}/ {print \$4}" "${ESCROW}/src/tlm/deps/manifest.cmake") \
        || fatal "Couldn't get version of $dependency in cache_deps"
      (

        cd $cache
        if [ ! -f "./$dependency-${platform}-x86_64-${version}.tgz.md5" ]
        then
          curl -O "http://packages.couchbase.com/couchbase-server/deps/$dependency/${version}/$dependency-${platform}-x86_64-${version}.{md5,tgz}" \
            || fatal "Package download failed"
          mv "$dependency-${platform}-x86_64-${version}.md5" "$dependency-${platform}-x86_64-${version}.tgz.md5"
        fi
      )
    done
  done
}

cache_openjdk() {
  echo "# Caching openjdk + openjdk_rt"
  sleep 5

  local openjdk_versions=$(awk '/SET \(_jdk_ver / {print substr($3, 1, length($3)-1)}' ${ESCROW}/src/analytics/cmake/Modules/FindCouchbaseJava.cmake) \
    || fatal "Couldn't get openjdk versions"
  echo "openjdk_versions: $openjdk_versions"
  for openjdk_version in $openjdk_versions
  do
    "${ESCROW}/deps/cbdep-${cbdep_ver_latest}-linux" install -n openjdk "${openjdk_version}" || fatal "OpenJDK install failed"
  done

  # mkdir -p ${ESCROW}/src/build/tlm/deps/openjdk-rt.exploded
  # local manifest=$(curl -Lvs https://raw.githubusercontent.com/couchbase/tlm/master/deps/manifest.cmake 2>/dev/null)
  # local openjdk_rt_versions=$(echo "$manifest" | awk "/openjdk-rt .*${PLATFORM}/ {print \$4}") \
  #   || fatal "Couldn't get openjdk-rt versions"
  # for openjdk_rt_version in $openjdk_rt_versions
  # do
  #   "${ESCROW}/deps/cbdep-${cbdep_ver_latest}-linux" install -d ${ESCROW}/deps/.cbdepscache openjdk-rt ${openjdk_rt_version}
  #   cp -rp ${ESCROW}/deps/.cbdepscache/openjdk-rt-${openjdk_rt_version}/openjdk-rt.jar ${ESCROW}/src/build/tlm/deps/openjdk-rt.exploded/openjdk-rt.jar
  # done
}

cache_analytics() {
  echo "# Caching analytics"
  VERSION_STRINGS=$(awk "/PACKAGE analytics-jars VERSION/ {print substr(\$5, 1, length(\$5)-1)}" "${ESCROW}/src/analytics/CMakeLists.txt") || fatal "Coudln't get analytics version"
  if [ -z "$VERSION_STRINGS" ]
  then
    fatal "Failed to retrieve analytics versions"
  fi
  for version in $VERSION_STRINGS
  do
    if [[ $version == \$\{*\} ]]; # if it's a parameter, we need to figure out what its value is
    then
      param=${version:2:${#version}-3}
      analytics_version=$(grep "SET ($param " "${ESCROW}/src/analytics/CMakeLists.txt" | cut -d'"' -f2)
    else
      analytics_version=$version
    fi
    analytics_version=${analytics_version/-*/}
    chmod +x ${ESCROW}/deps/cbdep-${cbdep_ver_latest}-linux
    "${ESCROW}/deps/cbdep-${cbdep_ver_latest}-linux" install -n analytics-jars "${analytics_version}" || fatal "Failed to cache analytics jars"
    "${ESCROW}/deps/cbdep-${cbdep_ver_latest}-linux" install -d ${ESCROW}/deps/.cbdepscache analytics-jars "${analytics_version}" || fatal "Failed to cache analytics jars"
  done

  mkdir -p ${ESCROW}/src/analytics/cbas/cbas-install/target/cbas-install-1.0.0-SNAPSHOT-generic/cbas/repo/compat/60x
  sed -i 's/PWD/pwd/g' "${ESCROW}/src/analytics/scripts/link_duplicates.sh"
}

copy_cbdepcache() {
  cp -rp ~/.cbdepcache/* ${ESCROW}/deps/.cbdepcache
}

sort_manifests() {
  echo "# Patch: Sort manifests: ${dep_manifest} ${dep_v2_manifest}"
  # sort -u to remove redundant cbdeps
  sort -u < "${dep_manifest}" > dep_manifest.tmp
  mv dep_manifest.tmp "${dep_manifest}"
  sort -u < "${dep_v2_manifest}" > dep_v2_manifest.tmp
  mv dep_v2_manifest.tmp "${dep_v2_manifest}"

  ### Ensure openssl build first, then rocksdb and folly built last
  grep -E openssl "${dep_manifest}" > "${ESCROW}/deps/dep2.txt"
  grep -Ev "^rocksdb|^folly|^openssl" "${dep_manifest}" >> "${ESCROW}/deps/dep2.txt"
  grep -E "^rocksdb|^folly" "${dep_manifest}" >> "${ESCROW}/deps/dep2.txt"
  mv "${ESCROW}/deps/dep2.txt" "${dep_manifest}"
  echo "dep_manifest=${dep_manifest}"
  echo "dep_v2_manifest=${dep_v2_manifest}"
}

get_cbdeps_versions() {
  # Interrogate CBDownloadDeps and curl_unix.sh style build scripts to generate a deduplicated array
  # of cbdeps versions.
  local versions=$(find "${1}/build-manifests/python_tools/cbdep" -name "*.xml" |  grep -Eo "[0-9\.]+.xml" | sed 's/\.[^.]*$//')
  versions=$(echo $versions | tr ' ' '\n' | sort -u | tr '\n' ' ')
  echo $versions
}

heading() {
  echo
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo "$@"
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo
}

ESCROW="${ROOT}/${PRODUCT}-${VERSION}"
echo "ESCROW=$ESCROW"
mkdir -p "${ESCROW}" 2>/dev/null || :

appdir="$(pwd)"

# Save copies of all Docker build images
heading "Saving Docker images..."
mkdir -p "${ESCROW}/docker_images" 2>/dev/null || :
pushd "${ESCROW}/docker_images"
for img in ${IMAGES}
do
  heading "Saving Docker image ${img}"
  if [ "$(docker image ls -q ${img})" == "" ]
  then
    echo "... Pulling ${img}..."
    docker pull "${img}"
  else
    echo "... Image already pulled"
  fi

  output=$(basename "${img}").tar.gz
  if [ ! -f ${output} ]
  then
    echo "... Saving local copy of ${img}..."
    if [ ! -s "${output}" ]
    then
      docker save "${img}" | gzip > "${output}"
    fi
  else
    echo "... Local copy already exists (${output})"
  fi
done
popd

# Get the source code
heading "Downloading released source code for ${PRODUCT} ${VERSION}..."
mkdir -p "${ESCROW}/src"
cd "${ESCROW}/src"
git config --global user.name "Couchbase Build Team"
git config --global user.email "build-team@couchbase.com"
git config --global color.ui false
repo init -u git://github.com/couchbase/manifest -g all -m "${MANIFEST_FILE}"
repo sync --jobs=6

# Ensure we have git history for 'master' branch of tlm, so we can
# switch to the right cbdeps build steps
( cd tlm && git fetch couchbase refs/heads/master )

# Download all cbdeps source code
mkdir -p "${ESCROW}/deps"
# Determine set of cbdeps used by this build, per platform.
for platform in ${PLATFORMS}
do
  add_packs=$(
    grep "${platform}" "${ESCROW}/src/tlm/deps/packages/folly/CMakeLists.txt" | grep -v V2 \
    | awk '{sub(/\(/, "", $2); print $2 ":" $4}';
    grep "${platform}" "${ESCROW}/src/tlm/deps/manifest.cmake" | grep -v V2 \
    | awk '{sub(/\(/, "", $2); print $2 ":" $4}'
  )
  add_packs_v2=$(
    grep "${platform}" "${ESCROW}/src/tlm/deps/packages/folly/CMakeLists.txt" | grep V2 \
    | awk '{sub(/\(/, "", $2); print $2 ":" $5 "-" $7}';
    grep "${platform}" "${ESCROW}/src/tlm/deps/manifest.cmake" | grep V2 \
    | awk '{sub(/\(/, "", $2); print $2 ":" $5 "-" $7}'
  )

  # Download and keep a record of all third-party deps
  dep_manifest=${ESCROW}/deps/dep_manifest_${platform}.txt
  dep_v2_manifest=${ESCROW}/deps/dep_v2_manifest_${platform}.txt

  rm -f "${dep_manifest}" "${dep_v2_manifest}"
  echo "${add_packs_v2}" > "${dep_v2_manifest}"

  # Get cbdeps V2 source first
  get_build_manifests_repo

  for add_pack in ${add_packs_v2}
  do
    dep=$(echo ${add_pack//:/ } | awk '{print $1}') # zlib
    ver=$(echo ${add_pack//:/ } | awk '{print $2}' | sed 's/-/ /' | awk '{print $1}') # 1.2.11
    bldnum=$(echo ${add_pack//: } | awk '{print $2}' | sed 's/-/ /' | awk '{print $2}')
    pushd "${ESCROW}/build-manifests/cbdeps" > /dev/null
    sha=$(git log --pretty=oneline "${dep}/${ver}/${ver}.xml" | grep "${ver}-${bldnum}" | awk '{print $1}')
    get_cbdeps2_src ${dep} ${ver} ${dep}/${ver}/${ver}.xml ${sha}
  done

  # Get cbdep after V2 source
  for add_pack in ${add_packs}
  do
    download_cbdep ${add_pack//:/ } "${dep_manifest}"
  done

  sort_manifests
done

# Need this tool for v8 build
get_cbdep_git depot_tools

CBDEPS_VERSIONS="$(get_cbdeps_versions "${ESCROW}")"

heading "Downloading cbdep versions: ${CBDEPS_VERSIONS}"
for cbdep_ver in ${CBDEPS_VERSIONS}
do
  [ ! -f "${ESCROW}/deps/cbdep-${cbdep_ver}-linux" ] && \
    curl -o "${ESCROW}/deps/cbdep-${cbdep_ver}-linux" "http://packages.couchbase.com/cbdep/${cbdep_ver}/cbdep-${cbdep_ver}-linux"
  chmod +x "${ESCROW}/deps/cbdep-${cbdep_ver}-linux"
done

cbdep_ver_latest=$(echo ${CBDEPS_VERSIONS} | tr ' ' '\n' | tail -1)

mkdir -p ${ESCROW}/deps/.cbdepcache

# Walk makelists to get go versions in use
GOVERS=$(echo $(find "${ESCROW}" -name CMakeLists.txt | xargs cat | awk '/GOVERSION [0-9]/ {print $2}' | grep -Eo "[0-9\.]+") | tr ' ' '\n' | sort -u | tr '\n' ' ')

heading "Downloading Go installers: ${GOVERS}"
mkdir -p "${ESCROW}/golang"
cd "${ESCROW}/golang"

for gover in ${GOVERS}
do
  echo "... Go ${gover}..."
  gofile="go${gover}.linux-amd64.tar.gz"
  if [ ! -e "${gofile}" ]
  then
    curl -o "${gofile}" "http://storage.googleapis.com/golang/${gofile}"
  fi
done

heading "Copying build scripts into escrow..."

cd "${appdir}"

cp -a ./escrow_config templates/* patches.sh "${ESCROW}/"

perl -pi -e "s/\@\@VERSION\@\@/${VERSION}/g; s/\@\@PLATFORMS\@\@/${PLATFORMS}/g; s/\@\@CBDEPS_VERSIONS\@\@/${CBDEPS_VERSIONS}/g;" \
  "${ESCROW}/README.md" "${ESCROW}/build-couchbase-server-from-escrow.sh" "${ESCROW}/patches.sh" "${ESCROW}/in-container-build.sh"

cache_deps

# OpenJDK must be handled after analytics as analytics cmake is interrogated for SDK version
cache_analytics
cache_openjdk
copy_cbdepcache

curl -Lo "${ESCROW}/deps/rsync" https://github.com/JBBgameich/rsync-static/releases/download/continuous/rsync-x86

heading "Done!"
