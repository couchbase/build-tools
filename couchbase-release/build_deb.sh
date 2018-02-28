#!/bin/bash

this_dir=$(dirname $0)
pushd ${this_dir}

STAGING=$1

if [[ "${STAGING}" == "yes" ]]; then
    STAGE_EXT="-staging"
else
    STAGE_EXT=""
fi

VERSION=1.0
RELEASE=6
REL_NAME="couchbase-release${STAGE_EXT}-${VERSION}-${RELEASE}"

rm -rf deb/${REL_NAME}

sed -e "s/%STAGING%/${STAGE_EXT}/g" \
    -e "s/%VERSION%/${VERSION}/g" \
    -e "s/%RELEASE%/${RELEASE}/g" \
    deb/tmpl/control.in > deb/debian_control_files/DEBIAN/control

mkdir -p deb/debian_control_files/etc/apt/sources.list.d
sed -e "s/%STAGING%/${STAGE_EXT}/g" deb/tmpl/couchbase.list.in \
    > deb/debian_control_files/etc/apt/sources.list.d/couchbase.list

cp -pr deb/debian_control_files deb/${REL_NAME}
mkdir -p deb/${REL_NAME}/etc/apt/trusted.gpg.d
cp -p GPG-KEY-COUCHBASE-1.0 deb/${REL_NAME}/etc/apt/trusted.gpg.d
sudo chown -R root:root deb/${REL_NAME}
dpkg-deb --build deb/${REL_NAME}
sudo chown -R ${USER}:${USER} deb/${REL_NAME}

popd

cp ${this_dir}/deb/${REL_NAME}.deb ${REL_NAME}-amd64.deb
