#!/bin/bash -e

# This script takes a version and release as arguments, before generating
# and testing .deb and .rpm packages for the couchbase package manager repos.
# Trigger it with:
#   ./run.sh [version] [release]
# e.g: ./run.sh 1.0 7

# Note: apt/yum output is suppressed unless $verbose is non-empty. Run with
# e.g. `verbose=1 ./run_tests.sh 1.0 999` to see unrestricted output

[ "$2" = "" ] && (echo "Usage: ./run_tests.sh [version] [release]" ; exit 1)

# Amazon linux versions currently have to be added manually
amazon_versions=( 2 )

if [[ -n $3 ]]; then
    STAGING="yes"
    STAGE_EXT="-staging"
else
    STAGING="no"
    STAGE_EXT=""
fi

heading() {
    local text=$@
    echo
    for ((i=0; i<${#text}+8; i++)) do echo -n "#"; done
    echo
    echo "#   $@   #"
    for ((i=0; i<${#text}+8; i++)) do echo -n "#"; done
    echo
    echo
}

heading "Discovering targets"

# Derive targeted platform versions from files in product-metadata/couchbase-server/repo_upload
yum_json=$(curl -L --silent https://raw.githubusercontent.com/couchbase/product-metadata/master/couchbase-server/repo_upload/yum.json)
centos_versions=$(jq -r .os_versions[] <<< $yum_json)

apt_json=$(curl -L --silent https://raw.githubusercontent.com/couchbase/product-metadata/master/couchbase-server/repo_upload/apt.json)
apt_versions=$(jq -r '.os_versions[] .full' <<< $apt_json)

# debian based distribution names - this is used to replace template
# strings in deb/debian_control_files/DEBIAN/{postinst,preinst}
distro_codenames=$(echo $(jq -r '.os_versions | keys[]' <<< $apt_json) | sed "s/ /|/g")

get_versions() {
    for apt_version in $apt_versions
    do
        name=$(grep -Eo "[a-z]+" <<< $apt_version)
        release=$(grep -Eo "[0-9\.]+" <<< $apt_version)
        if [ "$name" = "$1" ]
        then
          echo "$release"
        fi
    done
}

ubuntu_versions=("$(get_versions ubuntu)")
debian_versions=("$(get_versions debian)")

echo "Codenames: "$distro_codenames
echo "   CentOS: "$centos_versions
echo "   Debian: "$debian_versions
echo "   Ubuntu: "$ubuntu_versions
echo "   Amazon: "$amazon_versions
echo "  Staging: "${STAGING}

version=$1
release=$2

run_test() {
    # Takes 3 arguments, OS name (centos, debian or ubuntu), release version
    # and a test string - release version should match docker image tag
    [ "$3" = "" ] && echo "Fatal: Not enough arguments passed to run_test()" && exit 1
    local os_name=$1
    local os_ver=$2
    local test_cmd=$3
    heading "Testing ${os_name} ${os_ver}"
    if [ "${os_name}:${os_ver}" = "debian:7" ]
    then
      echo "Skipped"
      warnings="${warnings}debian 7 is untested\n"
    else
      if ! docker run --rm -it -v $(pwd):/app -w /app ${os_name}:${os_ver} bash -c "${test_cmd}"
      then
          failures="${failures}    ${os_name} ${os_ver}\n"
      fi
    fi
}

# To maintain portability between Linux and Mac OS, for in-place edits we let
# sed make backup files and delete them immediately after
sed -e "s/%DISTRO_CODENAMES%/${distro_codenames}/g" deb/debian_control_files/DEBIAN/postinst.in > deb/debian_control_files/DEBIAN/postinst
sed -e "s/%DISTRO_CODENAMES%/${distro_codenames}/g" deb/debian_control_files/DEBIAN/preinst.in > deb/debian_control_files/DEBIAN/preinst
sed -i'.bak' -e "s/^VERSION=.*/VERSION=${version}/" -e "s/^RELEASE=.*/RELEASE=${release}/" build_{rpm,deb}.sh
sed -i'.bak' -e "s/^Version:.*/Version: ${version}-${release}/" deb/debian_control_files/DEBIAN/control
chmod 755 deb/debian_control_files/DEBIAN/{pre,post}inst
rm -f build_*.sh.bak \
      deb/debian_control_files/DEBIAN/control.bak

# Tidy up the output of previous runs
for ext in deb rpm ; do [ -f couchbase-release*.${ext} ] && rm couchbase-release*.${ext}; done
rm -rf deb/couchbase-release*

# If verbose is unset, suppress all test output except the results of package searches
[ "$verbose" = "" ] &&
  redirect_all=" &>/dev/null" && \
  redirect_stderr="2>/dev/null" && \
  yum_quiet="-q" && \
  apt_quiet="-qq"

# glibc-langpack-en is required on CentOS 8 to prevent yum showing a warning
centos_test="export LANG=en_US.UTF-8 && \
export LANGUAGE=en_US.UTF-8 && \
( yum ${yum_quiet} install -y glibc-langpack-en ${redirect_all} || : ) && \
rpm -ivh couchbase-release${STAGE_EXT}-${version}-${release}*.rpm ${redirect_all} ; \
yum ${yum_quiet} list available '*couchbase*' --showduplicates"

# Debian and Ubuntu use the same test string
debian_test="command -v apt &>/dev/null && apt_cmd=apt || apt_cmd=apt-get && \
\${apt_cmd} ${apt_quiet} update ${redirect_all} && \
(\${apt_cmd} ${apt_quiet} install -y gpg ${redirect_all} \
  || \${apt_cmd} ${apt_quiet} install -y gpgv ${redirect_all} \
  || \${apt_cmd} ${apt_quiet} install -y gpgv2 ${redirect_all} ) && \
\${apt_cmd} ${apt_quiet} install -y lsb-release ${redirect_all} && \
dpkg -i couchbase-release${STAGE_EXT}-${version}-${release}*.deb ${redirect_all} && \
if ! update=\$(\${apt_cmd} update 2>&1); then stderr=${update} ; fi ; \
\${apt_cmd} ${apt_quiet} list -a '*couchbase*' ${redirect_stderr} && \
echo ${stderr}"

# Create CentOS build image
heading "Creating/Updating CentOS build container image"
docker build -t couchbase-release-centos -<<EOF
FROM centos:8
RUN yum install -y rpmdevtools
EOF

# Create Ubuntu build image
heading "Creating/Updating Ubuntu build container image"
docker build -t couchbase-release-ubuntu -<<EOF
FROM ubuntu:18.04
RUN apt update && apt install -y gpgv2 lsb-release sudo
EOF

# Create .rpm
heading "Creating .rpm"
docker run --rm -it -v $(pwd):/app -w /app couchbase-release-centos bash -c \
  "./build_rpm.sh ${STAGING}"

# Create .deb
heading "Creating .deb"
docker run --rm -it -v $(pwd):/app -w /app couchbase-release-ubuntu bash -c \
  "./build_deb.sh ${STAGING}"

if [ "$run_tests" = "no" ]; then exit 0; fi

# Run tests
for os in ${amazon_versions[@]}; do run_test amazonlinux ${os} "${centos_test}"; done
for os in ${centos_versions[@]}; do run_test centos ${os} "${centos_test}"; done
for os in ${debian_versions[@]}; do run_test debian ${os} "${debian_test}"; done
for os in ${ubuntu_versions[@]}; do run_test ubuntu ${os} "${debian_test}"; done

# Show output
if [ "${warnings}" != "" ];
then
  heading "WARNINGS"
  printf "${warnings}"
fi

if [ "${failures}" != "" ];
then
  heading "FAILED"
  printf "Fatal: Investigate failures affecting:\n${failures}\n"
  exit 1
else
  heading "All OK"
fi
