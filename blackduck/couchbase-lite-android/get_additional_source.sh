#!/bin/bash -ex
NDK_VERSION=$(cat cbl-java/common/etc/android/install_toolchain.sh | grep ^NDK_VERSION |awk -F "\'|\"" '{print $2}')
CMAKE_VERSION=$(cat cbl-java/common/etc/android/install_toolchain.sh | grep ^CMAKE_VERSION |awk -F "\'|\"" '{print $2}')
TOOLS_DIR=/home/couchbase/tools
SDK_DIR=${TOOLS_DIR}/android-sdk
SDK_MGR=${SDK_DIR}/tools/bin/sdkmanager
NDK_DIR=${SDK_DIR}/ndk/${NDK_VERSION}
CMAKE_DIR=${TOOLS_DIR}/cmake-${CMAKE_VERSION}
#sdkmanager doesn't work with jdk11, we have to install jdk8 here.
OPEN_JDK_VERSION=8u292-b10
curl https://packages.couchbase.com/cbdep/cbdep-linux -o cbdep
chmod +x cbdep
if [ ! -d ${TOOLS_DIR}/openjdk-${OPENJDK_VERSION} ]; then
  ./cbdep install -d ${TOOLS_DIR} openjdk ${OPEN_JDK_VERSION}
fi
JAVA_HOME=${TOOLS_DIR}/openjdk-${OPENJDK_VERSION}

if [ ! -d ${NDK_DIR} ]; then
  ${SDK_MGR} --install "ndk;${NDK_VERSION}"
fi
if [ ! -d ${CMAKE_DIR} ]; then
  ./cbdep install -d ${TOOLS_DIR} cmake ${CMAKE_VERSION}
fi
unset JAVA_HOME

if [ ! -f "local.properties" ]; then
    echo "ndk.dir=${NDK_DIR}" > local.properties
    echo "sdk.dir=${SDK_DIR}" >> local.properties
    echo "cmake.dir=${CMAKE_DIR}" >> local.properties
fi
cp local.properties cbl-java/local.properties
cp local.properties cbl-java/ce/android/local.properties
cp local.properties cbl-java/ee/android/local.properties
