#!/bin/bash -e

TOP=$(pwd)
platform=centos7

BOOST_VERSION='boost-1.67.0'

heading() {
  echo
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo $*
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo
}

get_cbdep_git() {
  local dep=$1
  local git_branch=$2

  cd ${TOP}/thirdparty-src/deps
  if [ ! -d ${dep} ]
  then
    heading "Downloading cbdep ${dep} ..."
    git clone --depth=1 --branch ${git_branch} git://github.com/couchbasedeps/${dep}.git
  fi
}

get_build_manifests_repo() {
  cd ${TOP}
  heading "Downloading build-manifests ..."
  rm -rf build-manifests
  git clone git://github.com/couchbase/build-manifests.git
}

get_cbdeps2_src() {
  local dep=$1
  local ver=$2
  local manifest=$3
  local sha=$4

  cd ${TOP}/thirdparty-src/deps
  if [ ! -d ${dep} ]
  then
    mkdir ${dep}
    cd ${dep}
    heading "Downloading cbdep2 ${manifest} at ${sha} ..."
    repo init -u ${TOP}/build-manifests -g all -m cbdeps/${manifest} -b ${sha}
    repo sync --jobs=6 --current-branch
    rm -rf build-tools cbbuild
  fi
}

download_cbdep() {
  local dep=$1
  local ver=$2
  local dep_manifest=$3

  # Split off the "version" and "build number"
  version=$(echo ${ver} | perl -nle '/^(.*?)(-cb.*)?$/ && print $1')
  cbnum=$(echo ${ver} | perl -nle '/-cb(.*)/ && print $1')

  # Figure out the tlm SHA which builds this dep
  tlmsha=$(
    cd ${TOP}/tlm &&
    git grep -c "_ADD_DEP_PACKAGE(${dep} ${version} .* ${cbnum})" \
      $(git rev-list --all -- deps/packages/CMakeLists.txt) \
      -- deps/packages/CMakeLists.txt \
    | awk -F: '{ print $1 }' | head -1
  )
  if [ -z "${tlmsha}" ]; then
    echo "ERROR: couldn't find tlm SHA for ${dep} ${version} @${cbnum}@"
    exit 1
  fi
  echo "${dep}:${tlmsha}:${ver}" >> ${dep_manifest}

  # Logic to get the tag/branch version of dep
  cd ${TOP}/tlm
  git reset --hard
  git clean -dfx
  git checkout ${tlmsha}
  dep_git_branch=$(
    git show ${tlmsha}:deps/packages/CMakeLists.txt |
    grep "_ADD_DEP_PACKAGE(${dep}" |
    sed 's/(/ /g' |
    awk '{print $4}'
  )

  echo
  echo "dep: $dep == ver: $ver == tlmsha: $tlmsha == dep_git_branch: $dep_git_branch"
  echo

  # skip openjdk-rt cbdeps build
  if [[ ${dep} == 'openjdk-rt' ]]
  then
    :
  else
    get_cbdep_git ${dep} ${dep_git_branch} || exit 1
  fi
}

# Main script starts here

mkdir -p ${TOP}/thirdparty-src/deps

add_packs=$(
  grep ${platform} ${TOP}/tlm/deps/packages/folly/CMakeLists.txt | grep -v V2 |
  awk '{sub(/\(/, "", $2); print $2 ":" $4}';
  grep ${platform} ${TOP}/tlm/deps/manifest.cmake | grep -v V2 |
  awk '{sub(/\(/, "", $2); print $2 ":" $4}'
)
add_packs_v2=$(
  grep ${platform} ${TOP}/tlm/deps/packages/folly/CMakeLists.txt | grep V2 |
  awk '{sub(/\(/, "", $2); print $2 ":" $5 "-" $7}';
  grep ${platform} ${TOP}/tlm/deps/manifest.cmake | grep V2 |
  awk '{sub(/\(/, "", $2); print $2 ":" $5 "-" $7}'
)
echo "add_packs: $add_packs"
echo
echo "add_packs_v2: $add_packs_v2"

# Download and keep a record of all third-party deps
dep_manifest=${TOP}/thirdparty-src/deps/dep_manifest_${platform}.txt
dep_v2_manifest=${TOP}/thirdparty-src/deps/dep_v2_manifest_${platform}.txt
echo "$add_packs_v2" > ${dep_v2_manifest}
rm -f ${dep_manifest}

# Rename .repo directory so we can create repo syncs in subdirs
if [ -d .repo ]
then
  mv .repo .repo.bak
fi

# Get cbdeps V2 source first
get_build_manifests_repo
for add_pack in ${add_packs_v2}
do
  dep=$(echo ${add_pack} | sed 's/:/ /g' | awk '{print $1}') # eg. "zlib"
  ver=$(echo ${add_pack} | sed 's/:/ /g' | awk '{print $2}' | sed 's/-/ /' | awk '{print $1}') # eg "1.2.11"
  bldnum=$(echo ${add_pack} | sed 's/:/ /g' | awk '{print $2}' | sed 's/-/ /' | awk '{print $2}') # eg. "1"
  pushd ${TOP}/build-manifests/cbdeps
  sha=$(git log --pretty=oneline ${dep}/${ver}/${ver}.xml | grep ${ver}-${bldnum} | awk '{print $1}')
  echo "dep: $dep == ver: $ver == sha: $sha == manifest: ${dep}/${ver}/${ver}.xml"
  get_cbdeps2_src ${dep} ${ver} ${dep}/${ver}/${ver}.xml ${sha} || exit 1
done

# Now that we're done repo init-ing, rename .repo back
cd ${TOP}
if [ -d .repo.bak ]
then
  mv .repo.bak .repo
fi

# Get cbdep after V2 source
for add_pack in ${add_packs}
do
  # skip download boost via cbdep_download
  _dep=$(echo ${add_pack} | sed 's/:/ /g' | sed 's/:/ /g' | awk '{print $1}')
  if [[ ${_dep} == 'boost' ]]; then
      continue
  else
    download_cbdep $(echo ${add_pack} | sed 's/:/ /g') ${dep_manifest} || exit 1
  fi
done

# boost download
pushd ${TOP}/thirdparty-src/deps
if [ ! -d 'boost' ]
then
    heading "Downloading cbdep boost ..."
    git clone --depth=1 git://github.com/boostorg/boost --branch ${BOOST_VERSION}
    for i in asio fusion geometry hana phoenix spirit typeof; do
        rm -rf boost/libs/$i
    done
fi
popd

# sort -u to remove redundant cbdeps
cat ${dep_manifest} | sort -u > dep_manifest.tmp
mv dep_manifest.tmp ${dep_manifest}
cat ${dep_v2_manifest} | sort -u > dep_v2_manifest.tmp
mv dep_v2_manifest.tmp ${dep_v2_manifest}

# And clean up build-manifests repo
rm -rf ${TOP}/build-manifests
