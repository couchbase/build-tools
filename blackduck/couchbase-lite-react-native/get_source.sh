#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

TOOLS_DIR=/home/couchbase/tools

# The default Detect (10.2.1) crashes on yarn.lock entries that use npm
# package aliases ("alias@npm:realname@range" - introduced here via
# @react-native/babel-plugin-codegen's @babel/traverse--for-generate-function-map),
# silently producing an empty YARN BOM while still reporting SUCCESS.
# Detect 10.7.0 handles these entries correctly.
export DETECT_JAR_VERSION=10.7.0

repo init -u https://github.com/couchbase/build-manifests -m ${PRODUCT}/${VERSION}/${VERSION}.xml
repo sync
rm -rf product-texts cbbuild

NODE_VERSION=$(curl -s https://nodejs.org/dist/index.json | \
    jq -r '.[] | select(.lts != false) | .version' | \
    head -1 | sed 's/^v//')
cbdep install nodejs ${NODE_VERSION} -d ${WORKSPACE}
export PATH=${WORKSPACE}//nodejs-${NODE_VERSION}/bin:${PATH}

# Evaluating the android project (AGP 8.x) requires JDK 17
OPENJDK_VERSION=17.0.7+7
if [ ! -d ${TOOLS_DIR}/openjdk-${OPENJDK_VERSION} ]; then
    cbdep install -d ${TOOLS_DIR} openjdk ${OPENJDK_VERSION}
fi

pushd ${PRODUCT}
    # The expo example app is not part of the shipped npm package; remove
    # it so its (large) dependency tree stays out of the scan.
    rm -rf expo-example

    # android/ is an Android library that is normally evaluated as part of
    # a consuming app's build. Give it a settings.gradle, an SDK location
    # and a JDK 17 so the GRADLE detector can evaluate it standalone.
    # detect-config.json restricts the included configurations to the
    # library's declared dependencies, so nothing is resolved against the
    # consuming app (e.g. react-native, which is a peer dependency).
    echo "rootProject.name = 'cbl-reactnative'" > android/settings.gradle
    echo "sdk.dir=${TOOLS_DIR}/android-sdk" > android/local.properties
    echo "org.gradle.java.home=${TOOLS_DIR}/openjdk-${OPENJDK_VERSION}" >> android/gradle.properties

    # The iOS side ships a podspec rather than a Podfile.lock (pod install
    # for a RN library only happens inside a consuming app, on macOS), so
    # synthesize a minimal Podfile.lock from the podspec's dependency
    # declarations for the COCOAPODS detector to pick up. Note: this only
    # handles exact-pinned "s.dependency 'Name', 'x.y.z'" declarations,
    # which is all the podspec currently contains.
    cat > ios/Podfile.lock <<EOF
PODS:
$(sed -nE "s/^[[:space:]]*s\.dependency[[:space:]]+'([^']+)',[[:space:]]*'([^']+)'.*$/  - \1 (\2)/p" cbl-reactnative.podspec)

DEPENDENCIES:
$(sed -nE "s/^[[:space:]]*s\.dependency[[:space:]]+'([^']+)',[[:space:]]*'([^']+)'.*$/  - \1 (= \2)/p" cbl-reactnative.podspec)

COCOAPODS: 1.15.2
EOF
    cat ios/Podfile.lock
popd
