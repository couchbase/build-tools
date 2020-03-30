#!/bin/bash -ex

SDK_DIR=/home/couchbase/tools/android-sdk
NDK_DIR=/home/couchbase/tools/android-sdk/ndk/20.1.5948944
if [ ! -f "local.properties" ]; then
    echo "ndk.dir=${NDK_DIR}" > local.properties
    echo "sdk.dir=${SDK_DIR}" >> local.properties
fi
cp local.properties couchbase-lite-android-ee/local.properties
