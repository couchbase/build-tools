#!/bin/bash -ex

function install_openjdk
{
    OPEN_JDK_VERSION="$1"
    if [ ! -d ${TOOLS_DIR}/openjdk-${OPEN_JDK_VERSION} ]; then
        cbdep install -d ${TOOLS_DIR} openjdk ${OPEN_JDK_VERSION}
    fi
}

# Install yq binary
function install_yq
{
    local yq_bin="${TOOLS_DIR}/bin/yq"
    if [ -x "${yq_bin}" ]; then
        return
    fi
    echo "Installing known-good yq ${YQ_VERSION}"
    mkdir -p "${TOOLS_DIR}/bin"
    local arch
    case "$(uname -m)" in
        aarch64|arm64) arch=arm64 ;;
        *) arch=amd64 ;;
    esac
    curl -sSL -o "${yq_bin}" \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"
    chmod +x "${yq_bin}"
}

# Bootstrap sdkmanager to ANDROID_HOME/cmdline-tools if it doesn't exist
function install_sdkmanager
{
    local sdk_mgr="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
    if [ -f "${sdk_mgr}" ]; then
        return
    fi
    echo "sdkmanager not found - installing Android commandline tools ${CMDLINE_TOOLS_VERSION}"
    mkdir -p "${ANDROID_HOME}/cmdline-tools"
    local zip_dir extract_dir
    zip_dir="$(mktemp -d)"
    extract_dir="$(mktemp -d)"
    curl -sSL -o "${zip_dir}/cmdline-tools.zip" \
        "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip"
    unzip -q "${zip_dir}/cmdline-tools.zip" -d "${extract_dir}"
    rm -rf "${ANDROID_HOME}/cmdline-tools/latest"
    mv "${extract_dir}/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"
    rm -rf "${zip_dir}" "${extract_dir}"
}

# Main
TOOLS_DIR=/home/couchbase/tools
export ANDROID_HOME=${TOOLS_DIR}/android-sdk
CMDLINE_TOOLS_VERSION=11076708
# Pin a known-good yq binary
# install_android_toolchain.sh relies on yq's filename-extension auto-detection of TOML
YQ_VERSION=v4.44.3

# cmdline-tools sdkmanager and Gradle both need JDK17+.
OPENJDK_VERSION=21.0.11+10
install_openjdk ${OPENJDK_VERSION}
export JAVA_HOME=${TOOLS_DIR}/openjdk-${OPENJDK_VERSION}
echo "org.gradle.java.home=${JAVA_HOME}" >> cbl-java/ee/android/gradle.properties

install_sdkmanager

TOOLCHAIN_SCRIPT="cbl-java/etc/jenkins/install_android_toolchain.sh"
if [ -f "${TOOLCHAIN_SCRIPT}" ]; then
    # Delegate NDK/CMake version resolution and ninja/cmake/build-tools/NDK
    # installation to cbl-java's own install_android_toolchain.sh
    install_yq
    export PATH="${TOOLS_DIR}/bin:${PATH}"
    export BIN_DIR="${TOOLS_DIR}"
    source "${TOOLCHAIN_SCRIPT}"
    # NDK_VERSION and CMAKE_VERSION are read from gradle/libs.versions.toml
    # by the sourced toolchain script
    if [ -z "${NDK_VERSION}" ] || [ "${NDK_VERSION}" = "null" ]; then
        echo "Could not detect NDK version - aborting!"
        exit 1
    fi
    if [ -z "${CMAKE_VERSION}" ] || [ "${CMAKE_VERSION}" = "null" ]; then
        echo "Could not detect CMake version - aborting!"
        exit 1
    fi
    NDK_DIR="${ANDROID_HOME}/ndk/${NDK_VERSION}"
    CMAKE_DIR="${TOOLS_DIR}/cmake-${CMAKE_VERSION}"
else
    # Older cbl-java branches predate install_android_toolchain.sh /
    # gradle/libs.versions.toml - fall back to the legacy grep-based approach.
    toolchain_script="cbl-java/ee/android/etc/jenkins/build.sh"
    if [ ! -f "${toolchain_script}" ]; then
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
    NDK_DIR=${ANDROID_HOME}/ndk/${NDK_VERSION}
    CMAKE_DIR=${TOOLS_DIR}/cmake-${CMAKE_VERSION}
    if [ ! -d ${NDK_DIR} ]; then
        "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" --install "ndk;${NDK_VERSION}"
    fi
    if [ ! -d ${CMAKE_DIR} ]; then
        cbdep install -d ${TOOLS_DIR} cmake ${CMAKE_VERSION}
    fi
fi

if [ ! -f "local.properties" ]; then
    echo "ndk.dir=${NDK_DIR}" > local.properties
    echo "sdk.dir=${ANDROID_HOME}" >> local.properties
    echo "cmake.dir=${CMAKE_DIR}" >> local.properties
fi
cp local.properties cbl-java/local.properties
cp local.properties cbl-java/ce/android/local.properties
cp local.properties cbl-java/ee/android/local.properties

NINJA_VERSION=1.11.1
cbdep install -d "${WORKSPACE}/extra" ninja ${NINJA_VERSION}
export PATH="${WORKSPACE}/extra/ninja-${NINJA_VERSION}/bin:${PATH}"
