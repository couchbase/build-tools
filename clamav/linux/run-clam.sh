#!/bin/bash -ex

# Update clamav database - we run cvdupdate locally
sudo /usr/local/bin/cvd update

# Download build
echo "Downloading ${PRODUCT} ${VERSION}-${BLD_NUM} ${PLATFORM} binary ..."
if [ "${PRODUCT}" = "sync_gateway" ]; then
    PKG_NAME=couchbase-sync-gateway-${EDITION}_${VERSION}-${BLD_NUM}_${ARCHITECTURE}.rpm
    SUDO=sudo
else
    PKG_NAME=${PRODUCT}-${EDITION}-${VERSION}-${BLD_NUM}-${PLATFORM}.${ARCHITECTURE}.rpm
    SUDO=
fi
LATESTBUILDS=http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PKG_NAME}
curl --fail ${LATESTBUILDS} -o ${WORKSPACE}/${PKG_NAME} || exit 1

echo "Extract ${VERSION}-${BLD_NUM} ${PLATFORM} binary ..."
mkdir -p ${WORKSPACE}/scansrc
pushd ${WORKSPACE}/scansrc
# Due to CBD-4731, have to run cpio as sudo and then fix permissions
# when handling sync_gateway
rpm2cpio ${WORKSPACE}/${PKG_NAME} | ${SUDO} cpio -idm || exit 1
if [ -d ./opt/couchbase-sync-gateway/examples ]; then
    cd ./opt/couchbase-sync-gateway/examples
    sudo find . -type d | sudo xargs chmod a+x
fi
popd

echo .................................
echo ClamAV Version
clamscan -V
echo .................................
clamscan --database /var/clamav/database --follow-dir-symlinks=2 --recursive=yes --suppress-ok-results -l ${WORKSPACE}/scan.log  ${WORKSPACE}/scansrc  || exit 1

grep 'Infected files: 0' ${WORKSPACE}/scan.log
if [[ $? != 0 ]]; then
    echo "ERROR!  Infected file(s) found!!"
    exit 1
fi
