#!/usr/bin/env bash
set -e
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -z "${PRODUCT}" ]; then
    echo "PRODUCT not set"
    exit 1
fi

if [ -z "${PROJECT}" ]; then
    echo "PROJECT not set"
    exit 1
fi

if [ -z "${SHAS}" ]; then
    echo "SHAS not set"
    exit 1
fi

if [ -z "${COMMENT}" ]; then
    echo "Comment not set"
    exit 1
fi

RELEASE_TRAINS=$(curl -sfL https://dbapi.build.couchbase.com/v1/products/${PRODUCT}/releases | jq -r '.releases.[]')

if [ -z "${RELEASE_TRAINS}" ]; then
    echo "Couldn't retrieve release list - check you are connected to the VPN"
    exit 2
fi

for RELEASE in ${RELEASES}; do
  if ! echo ${RELEASE_TRAINS} | grep ${RELEASE} &>/dev/null; then
    echo "Unknown release ${RELEASE}"
    exit 5
  fi
done

${SCRIPT_DIR}/../../utilities/clean_git_clone git@github.com:couchbase/product-metadata.git
cd product-metadata.git

for RELEASE in ${RELEASES}; do
  mkdir -p ${PRODUCT}/missing_commits/${RELEASE}
  pushd ${PRODUCT}/missing_commits/${RELEASE} &>/dev/null

  if [ -z "${SHAS}" ]; then
    touch ok-missing-commits.txt
  else
    for sha in ${SHAS}; do
        echo "${PROJECT} ${sha} ${COMMENT}" >> ok-missing-commits.txt
    done
  fi

  LC_ALL=C sort ok-missing-commits.txt | uniq > /tmp/ok.txt
  mv /tmp/ok.txt ok-missing-commits.txt
  git add ok-missing-commits.txt
  popd &>/dev/null
done

echo
echo
echo @@@@@@@@@@@@@@@@@@@@@@
echo @ resulting git diff @
echo @@@@@@@@@@@@@@@@@@@@@@
git diff HEAD
echo
echo

git commit -m "OK ${PROJECT} commits for ${RELEASES}"
git push origin HEAD:refs/heads/master
