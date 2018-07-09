#!/bin/bash

PRODUCT=$1
RELEASE_VERSION=$2
PUBLISH_URL=$3

cd ${WORKSPACE}/build-tools/mobile/lite-android/maven-publish-verification
gradle wrapper --gradle-version 4.8.1
./gradlew --gradle-user-home ${WORKSPACE}/gradle_home build

mkdir -p  ${WORKSPACE}/tmp
pushd ${WORKSPACE}/tmp
find ${WORKSPACE}/gradle_home/ -type f -name "couchbase*.aar"  |  xargs jar xvf

# Error if grep returns 0 for CE packages
for i in DatabaseEndpoint.class EncryptionKey.class; do
    jar tvf classes.jar | grep $i
     if [ $? == 0 ] && [ "${PRODUCT}" == 'couchbase-lite-android' ]; then
        echo "Error, Encryption keys found CE package"
        exit 1
    fi
done

popd
