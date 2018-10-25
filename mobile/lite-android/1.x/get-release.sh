#!/bin/bash
# 1.x Get release binaries from http://files.couchbase.com/maven2

VERSION="$1"
if [[ $# -ne 1 ]]; then
    echo "At least 1 argument (VERSION) is required!"
    exit 1
fi

#AAR
declare -a aar=("couchbase-lite-android" "couchbase-lite-android-sqlite-custom" "couchbase-lite-android-sqlcipher" "couchbase-lite-android-forestdb")
for name in "${aar[@]}"
do
    echo "$name"
    mkdir -p $name
    cd $name
    pwd
    wget http://files.couchbase.com/maven2/com/couchbase/lite/$name/$VERSION/$name-$VERSION-sources.jar
    wget http://files.couchbase.com/maven2/com/couchbase/lite/$name/$VERSION/$name-$VERSION.aar
    wget http://files.couchbase.com/maven2/com/couchbase/lite/$name/$VERSION/$name-$VERSION.pom
    cd ..
done

#JAR
declare -a aar=("couchbase-lite-java" "couchbase-lite-java-core" "couchbase-lite-java-javascript" "couchbase-lite-java-listener" "couchbase-lite-java-sqlite-custom" "couchbase-lite-java-sqlcipher" "couchbase-lite-java-forestdb")
for name in "${aar[@]}"
do
    echo "$name"
    mkdir -p $name
    cd $name
    pwd
    wget http://files.couchbase.com/maven2/com/couchbase/lite/$name/$VERSION/$name-$VERSION-sources.jar
    wget http://files.couchbase.com/maven2/com/couchbase/lite/$name/$VERSION/$name-$VERSION.jar
    wget http://files.couchbase.com/maven2/com/couchbase/lite/$name/$VERSION/$name-$VERSION.pom
    cd ..
done


