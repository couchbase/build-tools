#!/bin/bash

RELEASE_VERSION=$1
#REPOSITORY_ID=releases
REPOSITORY_ID='bintray-cb-buildteam-couchbase'

if [[ $# -ne 1 ]]; then
    echo "At least 1 argument (RELEASE_VERSION) is required!"
    exit 1
fi

# file patterns
javadoc_fl='*-javadoc.jar'
javasrc_fl='*-sources.jar'
GROUPID='com.couchbase.lite'

function maven_deploy {
    local PKG_FILE=$1
    local ARTIFACT_ID=$2
    local PKG_TYPE=$3
    local POM_OPTION=$4
    local CLASSIFIER=$5
    local APP_VERSION=${RELEASE_VERSION}
    local MVN_CMD="mvn --settings ./settings.xml -Dpublish.username=${PUBLISH_USERNAME} -Dpublish.password=${PUBLISH_PASSWORD} -DrepositoryId=${REPOSITORY_ID}"

    if [[ ! -z ${CLASSIFIER} ]]; then
        CLASSIFER_OPTION="-Dclassifier=${CLASSIFIER}"
    else
        CLASSIFER_OPTION=''
    fi

    CMD="${MVN_CMD} gpg:sign-and-deploy-file -Durl=${PUBLISH_URL} -DgroupId=${GROUPID} -DartifactId=${ARTIFACT_ID} -Dversion=${APP_VERSION} -Dfile=./${PKG_FILE} -Dpackaging=${PKG_TYPE} ${CLASSIFER_OPTION} ${POM_OPTION}"
    $CMD || exit $?
}

#AAR
declare -a aar=("couchbase-lite-android" "couchbase-lite-android-sqlite-custom" "couchbase-lite-android-sqlcipher" "couchbase-lite-android-forestdb")
for name in "${aar[@]}"; do
    local classifer=''
    pushd $name
    export PUBLISH_URL="https://api.bintray.com/maven/couchbase/couchbase/$name/;publish=1"
    #export PUBLISH_URL="http://nexus.build.couchbase.com:8081/nexus/content/repositories/releases"
        release_fl="$name-$RELEASE_VERSION.aar"
        ARTIFACT_ID=${name}
        RELEASE_FILES=$(ls ${release_fl} ${javadoc_fl} ${javasrc_fl})
        echo "${RELEASE_FILES}"
        # Loop through all files and publish to maven repo with RELEASE_VERSION
        for f in ${RELEASE_FILES}; do
            echo "Uploading file: $f "
            if [[ $f == ${javadoc_fl} ]]; then
                classifer='javadoc'
                pkgtype='jar'
                POM_OPTION='-DgeneratePom=false'
            elif [[ $f == ${javasrc_fl} ]]; then
                classifer='sources'
                pkgtype='jar'
                POM_OPTION='-DgeneratePom=false'
            elif [[ $f == ${release_fl} ]]; then
                classifer=''
                pkgtype='aar'
                POM_OPTION='-DpomFile='$name-$RELEASE_VERSION'.pom'
            fi
            maven_deploy $f ${ARTIFACT_ID} ${pkgtype} ${POM_OPTION} ${classifer}
        done
    popd

done

#JAR
declare -a aar=("couchbase-lite-java" "couchbase-lite-java-core" "couchbase-lite-java-javascript" "couchbase-lite-java-listener" "couchbase-lite-java-sqlite-custom" "couchbase-lite-java-sqlcipher" "couchbase-lite-java-forestdb")
for name in "${aar[@]}"; do
    pushd $name
    export PUBLISH_URL="https://api.bintray.com/maven/couchbase/couchbase/$name/;publish=1"
    #export PUBLISH_URL="http://nexus.build.couchbase.com:8081/nexus/content/repositories/releases"
    release_fl="$name-$RELEASE_VERSION.jar"
        ARTIFACT_ID=${name}
        RELEASE_FILES=$(ls ${release_fl} ${javadoc_fl} ${javasrc_fl})
        echo "${RELEASE_FILES}"
        # Loop through all files and publish to maven repo with RELEASE_VERSION
        for f in ${RELEASE_FILES}; do
            echo "Uploading file: $f "
            if [[ $f == ${javadoc_fl} ]]; then
                classifer='javadoc'
                pkgtype='jar'
                POM_OPTION='-DgeneratePom=false'
            elif [[ $f == ${javasrc_fl} ]]; then
                classifer='sources'
                pkgtype='jar'
                POM_OPTION='-DgeneratePom=false'
            elif [[ $f == ${release_fl} ]]; then
                classifer=''
                pkgtype='jar'
                POM_OPTION='-DpomFile='$name-$RELEASE_VERSION'.pom'
            fi
            maven_deploy $f ${ARTIFACT_ID} ${pkgtype} ${POM_OPTION} ${classifer}
        done
    popd
done
