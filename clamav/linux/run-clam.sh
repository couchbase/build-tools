#!/bin/bash -ex

#upgrade clamav in case it is outdated
sudo apt-get update
sudo apt-get install -y clamav-base clamav-daemon clamav-freshclam clamdscan

# Update clamav database
sudo freshclam

# Download build
echo "Downloading ${VERSION}-${BLD_NUM} ${PLATFORM} binary ..."
PKG_NAME=${PRODUCT}-${EDITION}-${VERSION}-${BLD_NUM}-${PLATFORM}.x86_64.rpm
LATESTBUILDS=http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PKG_NAME}
curl --fail ${LATESTBUILDS} -o ${WORKSPACE}/${PKG_NAME} || exit 1

echo "Extract ${VERSION}-${BLD_NUM} ${PLATFORM} binary ..."
mkdir -p ${WORKSPACE}/scansrc
pushd ${WORKSPACE}/scansrc
/usr/bin/rpm2cpio ${WORKSPACE}/${PKG_NAME}  | /bin/cpio -idm || exit 1
popd

echo .................................
echo ClamAV Version
/usr/bin/clamscan -V
echo .................................
/usr/bin/clamscan  --follow-dir-symlinks=2 --recursive=yes --suppress-ok-results -l ${WORKSPACE}/scan.log  ${WORKSPACE}/scansrc  || exit 1

grep 'Infected files: 0' ${WORKSPACE}/scan.log
if [[ $? != 0 ]]; then
    echo "ERROR!  Infected file(s) found!!"
    exit 1
fi
