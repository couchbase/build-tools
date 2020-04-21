#!/bin/bash -ex
NDK_VERSION=$(cat cbl-java/ee/android/etc/jenkins/build.sh | grep ^NDK_VERSION |awk -F "\'|\"" '{print $2}')
SDK_DIR=/home/couchbase/tools/android-sdk
SDK_MGR=${SDK_DIR}/tools/bin/sdkmanager
NDK_DIR=${SDK_DIR}/ndk/${NDK_VERSION}
if [ ! -d ${NDK_DIR} ]; then
  ${SDK_MGR} --install "ndk;${NDK_VERSION}"
fi
if [ ! -f "local.properties" ]; then
    echo "ndk.dir=${NDK_DIR}" > local.properties
    echo "sdk.dir=${SDK_DIR}" >> local.properties
fi
cp local.properties cbl-java/local.properties
cp local.properties cbl-java/ce/android/local.properties
cp local.properties cbl-java/ee/android/local.properties
