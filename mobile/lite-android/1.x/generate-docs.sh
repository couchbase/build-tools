#!/bin/bash
# Generate README, javadocs and javasources

VERSION="$1"
if [[ $# -ne 1 ]]; then
    echo "At least 1 argument (VERSION) is required!"
    exit 1
fi

#AAR - javadocs
declare -a aar=("couchbase-lite-android" "couchbase-lite-android-sqlite-custom" "couchbase-lite-android-sqlcipher" "couchbase-lite-android-forestdb")
for name in "${aar[@]}"
do
    git_org=couchbase
    cd $name
    pwd
    case "$name" in
        "couchbase-lite-android-sqlite-custom")
            git_name=couchbase-lite-java-native
            ;;
        "couchbase-lite-android-sqlcipher")
            git_name=couchbase-lite-java-native
            ;;
        "couchbase-lite-android-forestdb")
            git_name=couchbase-lite-java-forestdb
            git_org=couchbaselabs
            ;;
        *)
            git_name=${name}
    esac
    echo "Source Code Repository: https://github.com/${git_org}/$git_name.git" > README
    jar -cvf $name-$VERSION-javadoc.jar README
    cd ..
done

#JAR - javadocs
declare -a aar=("couchbase-lite-java" "couchbase-lite-java-core" "couchbase-lite-java-javascript" "couchbase-lite-java-listener" "couchbase-lite-java-sqlite-custom" "couchbase-lite-java-sqlcipher" "couchbase-lite-java-forestdb")
for name in "${aar[@]}"
do
    git_org=couchbase
    cd $name
    pwd
    case "$name" in
        "couchbase-lite-java-sqlite-custom")
            git_name=couchbase-lite-java-native
            ;;
        "couchbase-lite-java-sqlcipher")
            git_name=couchbase-lite-java-native
            ;;
        "couchbase-lite-java-forestdb")
            git_name=couchbase-lite-java-forestdb
            git_org=couchbaselabs
            ;;
        *)
            git_name=${name}
    esac
    echo "Source Code Repository: https://github.com/${git_org}/$git_name.git" > README
    jar -cvf $name-$VERSION-javadoc.jar README
    cd ..
done

# Generate sources
declare -a aar=("couchbase-lite-java" "couchbase-lite-android-sqlite-custom" "couchbase-lite-android-sqlcipher" "couchbase-lite-android-forestdb" "couchbase-lite-java-sqlite-custom" "couchbase-lite-java-sqlcipher" "couchbase-lite-java-forestdb" "couchbase-lite-java-javascript")
for name in "${aar[@]}"
do
    cd $name
    pwd
    jar -cvf $name-$VERSION-sources.jar README
    cd ..
done
