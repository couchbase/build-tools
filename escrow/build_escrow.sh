#!/bin/bash
set -e
source ./escrow_config || exit 1

# Top-level directory; everything to escrow goes in here.
if [ -z "$1" ]
then
  echo "Usage: $0 /path/to/output/files"
  exit 1
fi

# Make sure we're using an absolute path
mkdir -p $1
pushd $1
ROOT=$(pwd)
popd

ESCROW="${ROOT}/${PRODUCT}-${VERSION}"

if [[ "$OSTYPE" == "darwin"* ]]
then
  OS=darwin
else
  OS=linux
fi

heading() {
  echo
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo "$@"
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo
}

fatal() {
  echo "FATAL: $@"
  exit 1
}

cache_deps() {
  # Parses tlm/deps/manifest.cmake, downloading each package
  # to ${ESCROW}/deps/.cbdepscache
  echo "# Caching deps"

  local cache=${ESCROW}/.cbdepscache
  mkdir -p $cache || :
  pushd $cache

  for platform in amzn2 linux centos7 all
  do
    echo "platform: ${platform}"
      urls=$(awk "/^DECLARE_DEP.*[^A-Za-z0-9]$platform[^A-Za-z0-9]/ {
        if(\$4 ~ /VERSION/) {
          url = \"https://packages.couchbase.com/couchbase-server/deps/\" substr(\$2,2) \"/\" \$5 \"/\" \$7 \"/\" substr(\$2,2) \"-${platform}-x86_64-\" \$5 \"-\" \$7;
          print url \".md5\";
          print url \".tgz\";
        } else {
          url = \"https://packages.couchbase.com/couchbase-server/deps/\" substr(\$2,2) \"/\" \$4 \"/\" substr(\$2,2) \"-${platform}-x86_64-\" \$4;
          print url \".md5\";
          print url \".tgz\";
        }
      }" "${ESCROW}/src/tlm/deps/manifest.cmake")
      if [ "${platform}" = "amzn2" -o "${platform}" = "linux" ]
      then
        # If platform is amzn2 or linux, we need to get x86-64 and aarch64
        for url in $urls
        do
          urls="$urls ${url/x86_64/aarch64}"
        done
      elif [ "${platform}" = "all" ]
      then
        # If platform is "all" we need to get the all/noarch build
        # and the amzn2/aarch64 build
        _urls=""
        for url in $urls
        do
            _url="${url/all/amzn2}"
            _urls="${_urls} ${_url}"
            _urls="${_urls} ${_url/-x86_64-/-aarch64-}"
          _urls="${url/-x86_64-/-noarch-} $_urls"
        done
        urls=$_urls
      fi
      for url in $urls
      do
        if [ ! -f "$(basename $url)" ]; then
          echo "Fetching $url"
          curl -fO "$url" \
            || fatal "Package download failed"
        else
          echo "$(pwd)/$(basename $url) already present"
        fi
      done
  done
  popd
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
      _v=$(grep "SET ($param " "${ESCROW}/src/analytics/CMakeLists.txt" | cut -d'"' -f2)
    else
      _v=$version
    fi
    analytics_version=$(echo $_v | sed 's/-.*//')
    analytics_build=$(echo $_v | sed 's/.*-//')

    if [ ! -f "${ESCROW}/.cbdepscache/analytics-jars-${analytics_version}-${analytics_build}.tar.gz" ]
    then
      (
        # .cbdepscache gets copied into the build container - this target is a
        # convenience to make sure the files are available later
        cd ${ESCROW}/.cbdepscache
        curl --fail -LO https://packages.couchbase.com/releases/${analytics_version}/analytics-jars-${analytics_version}-${analytics_build}.tar.gz
      )
    fi
  done

  mkdir -p ${ESCROW}/src/analytics/cbas/cbas-install/target/cbas-install-1.0.0-SNAPSHOT-generic/cbas/repo/compat/60x
}

cache_openjdk() {
  echo "# Caching openjdk"
  local openjdk_versions=$(awk '/SET \(_jdk_ver / {print substr($3, 1, length($3)-1)}' ${ESCROW}/src/analytics/cmake/Modules/FindCouchbaseJava.cmake) \
    || fatal "Couldn't get openjdk versions"
  echo "openjdk_versions: $openjdk_versions"
  for openjdk_version in $openjdk_versions
  do
    "${ESCROW}/deps/cbdep-${cbdep_ver_latest}-${OS}-$(uname -m)" -p linux install -d ${ESCROW}/.cbdepscache -n openjdk "${openjdk_version}" || fatal "OpenJDK install failed"
  done
}

get_cbdep_git() {
  local dep=$1
  local version=$2
  local bldnum=$3

  if [ ! -d "${ESCROW}/deps/src/${dep}-${version}-cb${bldnum}" -a "${dep}" != "cbpy" ]
  then
    depdir="${ESCROW}/deps/src/${dep}-${version}-cb${bldnum}"
    mkdir -p "${depdir}"

    heading "Downloading cbdep ${dep} ..."
    # This special approach ensures all remote branches are brought
    # down as well, which ensures in-container-build.sh can also check
    # them out. See https://stackoverflow.com/a/37346281/1425601 .
    pushd "${depdir}"
    if [ ! -d .git ]
    then
      git clone --bare "ssh://git@github.com/couchbasedeps/${dep}.git" .git
    fi
    git config core.bare false
    git checkout
    popd
  fi
}

get_cbdeps2_src() {
  local dep=$1
  local ver=$2
  local manifest=$3
  local sha=$4
  local bldnum=$5

  if [ ! -d "${ESCROW}/deps/src/${dep}-${ver}-cb${bldnum}" ]
  then
    mkdir -p "${ESCROW}/deps/src/${dep}-${ver}-cb${bldnum}"
    pushd "${ESCROW}/deps/src/${dep}-${ver}-cb${bldnum}"
    heading "Downloading cbdep2 ${manifest} at ${sha} ..."
    repo init -u ssh://git@github.com/couchbase/build-manifests -g all -m "cbdeps/${manifest}" -b "${sha}"
    repo sync --jobs=6
    popd
  fi
}

download_cbdep() {
  local dep=$1
  local ver=$2
  local dep_manifest=$3
  local platform=$4
  heading "download_cbdep - $dep $ver $dep_manifest $platform"

  # Split off the "version" and "build number"
  version=$(echo "${ver}" | perl -nle '/^(.*?)(-cb.*)?$/ && print $1')
  cbnum=$(echo "${ver}" | perl -nle '/-cb(.*)/ && print $1')

  # skip openjdk-rt cbdeps build
  if [[ ${dep} == 'openjdk-rt' ]]
  then
    :
  else
    get_cbdep_git "${dep}" "${version}" "${cbnum}"
  fi

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

copy_cbdepcache() {
  mkdir -p ${ESCROW}/.cbdepcache
  if [ "${OS}" = "linux" ]; then cp -rp ~/.cbdepcache/* ${ESCROW}/.cbdepcache; fi
}

copy_container_images() {
  # Save copies of all Docker build images
  heading "Saving Docker images..."
  mkdir -p "${ESCROW}/docker_images" 2>/dev/null || :
  pushd "${ESCROW}/docker_images"
  for img in ${IMAGES}
  do
    if [[ "${img}" = *"amzn2"* ]]; then
      platform_arg="--platform linux/arm64"
    else
      unset platform_arg
    fi
    heading "Saving Docker image ${img}"
    echo "... Pulling ${img}..."
    docker pull ${platform_arg} "${img}"

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
}

get_build_manifests_repo() {
  heading "Downloading build-manifests ..."
  pushd "${ESCROW}"
  if [ ! -d build-manifests ]
  then
    git clone ssh://git@github.com/couchbase/build-manifests.git
  else
    (cd build-manifests && git fetch origin master)
  fi
  popd
}

get_cbdeps_versions() {
  # Interrogate CBDownloadDeps and curl_unix.sh style build scripts to generate a deduplicated array
  # of cbdeps versions.
  local versions=$(find "${1}/build-manifests/python_tools/cbdep" -name "*.xml" |  grep -Eo "[0-9\.]+.xml" | sed 's/\.[^.]*$//')
  versions=$(echo $versions | tr ' ' '\n' | sort -uV | tr '\n' ' ')
  echo $versions
}

# Retrieve list of current Docker image/tags from stackfile
stackfile=$(curl -L --fail https://raw.githubusercontent.com/couchbase/build-infra/master/docker-stacks/couchbase-server/server-jenkins-agents.yml)

python3 -m venv escrow_venv
source escrow_venv/bin/activate
pip3 install pyyaml

IMAGES=$(python3 - <<EOF
import yaml

stack = yaml.safe_load("""
${stackfile}
""")

for service in ['amzn2', 'linux-single']:
    print(stack['services'][service]['image'])
EOF
)

# Get the source code
heading "Downloading released source code for ${PRODUCT} ${VERSION}..."
mkdir -p "${ESCROW}/src"
pushd "${ESCROW}/src"
git config --global user.name "Couchbase Build Team"
git config --global user.email "build-team@couchbase.com"
git config --global color.ui false
git config --global url."https://github.com/".insteadOf git://github.com/
repo init -u ssh://git@github.com/couchbase/manifest -g all -m "${MANIFEST_FILE}"
repo sync --jobs=6

# Ensure we have git history for 'master' branch of tlm, so we can
# switch to the right cbdeps build steps
( cd tlm && git fetch couchbase refs/heads/master )

# Download all cbdeps source code
mkdir -p "${ESCROW}/deps/src"
echo "This directory contains third party dependency sources.

Sources are included for reference, and are not compiled when building the escrow deposit." > "${ESCROW}/deps/src/README.md"

# Determine set of cbdeps used by this build, per platform.
for platform in amzn2 centos7 linux all
do
  platform=$(echo ${platform} | sed 's/-.*//')
  add_packs=$(
    grep "DECLARE_DEP.*${platform}" "${ESCROW}/src/tlm/deps/packages/folly/CMakeLists.txt" | grep -v V2 \
    | awk '{sub(/\(/, "", $2); print $2 ":" $4}';
    grep "DECLARE_DEP.*${platform}" "${ESCROW}/src/tlm/deps/manifest.cmake" | grep -v V2 \
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
    dep=$(echo ${add_pack//:/ } | awk '{print $1}')
    ver=$(echo ${add_pack//:/ } | awk '{print $2}' | sed 's/-/ /' | awk '{print $1}')
    bldnum=$(echo ${add_pack//:/ } | awk '{if ($2) { print $2 } else { print $1 }}' | sed 's/-/ /' | awk '{print $2}')
    pushd "${ESCROW}/build-manifests/cbdeps" > /dev/null
    sha=$(git log --pretty=oneline "${dep}/${ver}/${ver}.xml" | grep "${ver}-${bldnum}" | awk '{print $1}')
    get_cbdeps2_src ${dep} ${ver} ${dep}/${ver}/${ver}.xml ${sha} ${bldnum}
    popd
  done

  # Get cbdep after V2 source
  for add_pack in ${add_packs}
  do
    download_cbdep ${add_pack//:/ } "${dep_manifest}" ${platform}
  done
done

# Need this tool for v8 build
get_cbdep_git depot_tools

get_build_manifests_repo
popd

# Get cbdeps binaries
CBDEP_VERSIONS="$(get_cbdeps_versions "${ESCROW}")"
heading "Downloading cbdep versions: ${CBDEP_VERSIONS}"
for cbdep_ver in ${CBDEP_VERSIONS}
do
  if [ ! -f "${ESCROW}/deps/cbdep-${cbdep_ver}-linux" ]
  then
    filename="cbdep-${cbdep_ver}-linux"
    cbdep_url="https://packages.couchbase.com/cbdep/${cbdep_ver}/${filename}"
    printf "Retrieving cbdep ${cbdep_ver}... "
    set +e
    curl -s --fail -L -o "${ESCROW}/deps/${filename}" "${cbdep_url}"
    # Try to get platform specific binaries - these won't exist for
    # old versions
    for arch in x86_64 aarch64
    do
      curl -s --fail -L -o "${ESCROW}/deps/${filename}-${arch}" "${cbdep_url}-${arch}"
    done
    set -e
    chmod a+x ${ESCROW}/deps/cbdep-*
  fi
done
cbdep_ver_latest=$(echo ${CBDEP_VERSIONS} | tr ' ' '\n' | tail -1)

# Get go versions
GOVERS="$(echo $(find "${ESCROW}" -name CMakeLists.txt | xargs cat | awk '/GOVERSION [0-9]/ {print $2}' | grep -Eo "[0-9\.]+") | tr ' ' '\n' | sort -u | tr '\n' ' ') $EXTRA_GOLANG_VERSIONS"
heading "Downloading Go installers: ${GOVERS}"
mkdir -p "${ESCROW}/golang"
pushd "${ESCROW}/golang"
for gover in ${GOVERS}
do
  echo "... Go ${gover}..."
  gofile="go${gover}.linux-amd64.tar.gz"
  if [ ! -e "${gofile}" ]
  then
    curl -o "${gofile}" "http://storage.googleapis.com/golang/${gofile}"
  fi
done
popd

heading "Copying build scripts into escrow..."

cp -a ./escrow_config templates/* "${ESCROW}/"
perl -pi -e "s/\@\@VERSION\@\@/${VERSION}/g; s/\@\@CBDEP_VERSIONS\@\@/${CBDEP_VERSIONS}/g;" \
  "${ESCROW}/README.md" "${ESCROW}/build-couchbase-server-from-escrow.sh" "${ESCROW}/in-container-build.sh"

cache_deps
# OpenJDK must be handled after analytics as analytics cmake is interrogated for SDK version
cache_analytics
cache_openjdk

copy_cbdepcache
copy_container_images

echo "Downloading rsync to ${ESCROW}/deps/rsync"
for arch in aarch64 x86
do
  if [ "${arch}" = "x86" ]
  then
    dest_arch=x86_64
  else
    dest_arch=aarch64
  fi
  curl -fLo "${ESCROW}/deps/rsync-${dest_arch}" https://github.com/JBBgameich/rsync-static/releases/download/continuous/rsync-${arch}
  chmod a+x "${ESCROW}/deps/rsync-${dest_arch}"
done
heading "Done!"
