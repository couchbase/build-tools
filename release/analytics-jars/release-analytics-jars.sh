#!/bin/bash -ex

RELEASE=$1
VERSION=$2
BLD_NUM=$3
PRODUCT=$4

if [ "${PRODUCT}" = "couchbase-columnar" ]; then
  JAR_PREFIX=columnar
elif [ "${PRODUCT}" = "couchbase-server" ]; then
  JAR_PREFIX=cbas
else
  echo PRODUCT must be 'couchbase-columnar' or 'couchbase-server' but was $PRODUCT
  exit 1
fi

# Download named build (try linux, falling back to Ubuntu 20 then debian10)
curl -f -L http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}-enterprise_${VERSION}-${BLD_NUM}-linux_amd64.deb -o ${PRODUCT}.deb ||
  curl -f -L http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}-enterprise_${VERSION}-${BLD_NUM}-ubuntu20.04_amd64.deb -o ${PRODUCT}.deb ||
  curl -f -L http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}-enterprise_${VERSION}-${BLD_NUM}-debian10_amd64.deb -o ${PRODUCT}.deb

# Extract jar contents
ar x ${PRODUCT}.deb
tar xf data.tar.xz --wildcards --strip-components 5 './opt/couchbase/lib/c*/repo/*.jar'

# Create new jarball and checksum
TARGET_NAME=${JAR_PREFIX}-jars-all-noarch-${VERSION}-${BLD_NUM}
pushd repo

INSTALLER_JAR=${JAR_PREFIX}-install-${VERSION}.jar
INSTALLER_JAR_ALT=${JAR_PREFIX}-install-${VERSION}-${BLD_NUM}.jar
if [ ! -f "${INSTALLER_JAR}" ]; then
  if [ ! -f "${INSTALLER_JAR_ALT}" ]; then
    echo "Cannot locate installer jar (tried ${INSTALLER_JAR} and ${INSTALLER_JAR_ALT})"
    exit 1
  else
    INSTALLER_JAR=${INSTALLER_JAR_ALT}
  fi
fi
# TODO(mblow): this will need to be reworked if we ever have jars with a space in the name...
unzip -p ${INSTALLER_JAR} META-INF/MANIFEST.MF | sed 's/^ /@@/g' | sed 's/@@@/#/g' | grep '\(^Class-Path\|^@@\)' \
  | tr -d '\r' | tr -d '\n' | sed -e 's/@@//g' -e 's/^Class-Path: //' | xargs -n1 \
  | tar cvzf ../${TARGET_NAME}.tgz -T - ${INSTALLER_JAR}
popd
md5sum ${TARGET_NAME}.tgz | cut -c -32 > ${TARGET_NAME}.md5

# Publish to S3 and internal release mirror
CBDEPS_DIR=${JAR_PREFIX}-jars/${VERSION}-${BLD_NUM}
for ext in tgz md5; do
  mkdir -p /releases/cbdeps/${CBDEPS_DIR}
  cp ${TARGET_NAME}.${ext} /releases/cbdeps/${CBDEPS_DIR}/${TARGET_NAME}.${ext}
  aws s3 cp --acl public-read \
    ${TARGET_NAME}.${ext} \
    s3://packages.couchbase.com/couchbase-server/deps/${CBDEPS_DIR}/${TARGET_NAME}.${ext}
done
