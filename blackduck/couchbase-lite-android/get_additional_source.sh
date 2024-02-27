#!/bin/bash -ex

function install_openjdk
{
    OPEN_JDK_VERSION="$1"
    if [ ! -d ${TOOLS_DIR}/openjdk-${OPENJDK_VERSION} ]; then
        cbdep install -d ${TOOLS_DIR} openjdk ${OPEN_JDK_VERSION}
    fi
}

# Main
if [ -f "cbl-java/etc/jenkins/install_android_toolchain.sh" ]; then
    toolchain_script="cbl-java/etc/jenkins/install_android_toolchain.sh"
elif [ -f "cbl-java/ee/android/etc/jenkins/build.sh" ]; then
    toolchain_script="cbl-java/ee/android/etc/jenkins/build.sh"
else
    echo "Could not locate toolchain script containing CMake and NDK_VERSION - aborting!"
    exit 1
fi
NDK_VERSION=$(cat ${toolchain_script} | grep ^NDK_VERSION |awk -F "\'|\"" '{print $2}')
CMAKE_VERSION=$(cat ${toolchain_script} | grep ^CMAKE_VERSION |awk -F "\'|\"" '{print $2}')
if [ -z "${NDK_VERSION}" ]; then
    echo "Could not detect NDK version - aborting!"
    exit 1
fi
if [ -z "${CMAKE_VERSION}" ]; then
    echo "Could not detect CMake version - aborting!"
    exit 1
fi
TOOLS_DIR=/home/couchbase/tools
SDK_DIR=${TOOLS_DIR}/android-sdk
SDK_MGR=${SDK_DIR}/tools/bin/sdkmanager
NDK_DIR=${SDK_DIR}/ndk/${NDK_VERSION}
CMAKE_DIR=${TOOLS_DIR}/cmake-${CMAKE_VERSION}

#sdkmanager doesn't work with jdk11, we have to install jdk8 here.
OPENJDK_VERSION=8u292-b10
install_openjdk ${OPENJDK_VERSION}
JAVA_HOME=${TOOLS_DIR}/openjdk-${OPENJDK_VERSION}

if [ ! -d ${NDK_DIR} ]; then
  ${SDK_MGR} --install "ndk;${NDK_VERSION}"
fi
unset JAVA_HOME

# Gradle needs JDK17.
OPENJDK_VERSION=17.0.7+7
install_openjdk ${OPENJDK_VERSION}
echo "org.gradle.java.home=${TOOLS_DIR}/openjdk-${OPENJDK_VERSION}" >> cbl-java/ee/android/gradle.properties

if [ ! -d ${CMAKE_DIR} ]; then
  cbdep install -d ${TOOLS_DIR} cmake ${CMAKE_VERSION}
fi

if [ ! -f "local.properties" ]; then
    echo "ndk.dir=${NDK_DIR}" > local.properties
    echo "sdk.dir=${SDK_DIR}" >> local.properties
    echo "cmake.dir=${CMAKE_DIR}" >> local.properties
fi
cp local.properties cbl-java/local.properties
cp local.properties cbl-java/ce/android/local.properties
cp local.properties cbl-java/ee/android/local.properties

NINJA_VERSION=1.11.1
cbdep install -d "${WORKSPACE}/extra" ninja ${NINJA_VERSION}
export PATH="${WORKSPACE}/extra/ninja-${NINJA_VERSION}/bin:${PATH}"
