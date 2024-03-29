#!/bin/bash
# Publish built packages from internal_maven to maven repo

function usage() {
    echo
    echo "$0 -r <product>  -r <release> -v <version> -b <build-number>"
    echo "where:"
    echo "  -p: product name: sync_gateway, couchbase-lite-ios"
    echo "  -r: release branch: master, 1.5.0, etc."
    echo "  -v: version number: 3.2.0, etc."
    echo "  -b: build number: 128, etc."
    echo "  -s: version suffix, eg. 'MP1' or 'beta' [optional]"
    echo
}

function update_version {
    mv ${pom_file} ${POM_FILE}
    echo "Update release version in ${POM_FILE} \n"
    OLD_VERSION="${RELEASE}-${BLD_NUM}"
    sed -i.bak "s#<version>${OLD_VERSION}</version>#<version>${VERSION}</version>#" ${POM_FILE} || exit 1
    diff ${POM_FILE} ${POM_FILE}.bak
}

function maven_deploy {
    local PKG_FILE=$1
    local PKG_TYPE=$2
    local CLASSIFIER=$3
    local ARTIFACT_ID=${PUBLISH_NAME}
    local APP_VERSION=${VERSION}
    local MVN_CMD="mvn --settings ./settings.xml -Dpublish.username=${PUBLISH_USERNAME} -Dpublish.password=${PUBLISH_PASSWORD} -DrepositoryId=${REPOSITORY_ID}"

    if [[ ${PKG_FILE} == *".aar" ]]; then
        POM_OPTION='-DpomFile='${POM_FILE}
    else
        POM_OPTION='-DgeneratePom=false'
    fi
    if [[ ! -z ${CLASSIFIER} ]]; then
        CLASSIFER_OPTION="-Dclassifier=${CLASSIFIER}"
    else
        CLASSIFER_OPTION=''
    fi

    CMD="${MVN_CMD} gpg:sign-and-deploy-file -Durl=${PUBLISH_URL} -DgroupId=${GROUPID} -DartifactId=${ARTIFACT_ID} -Dversion=${APP_VERSION} -Dfile=./${PKG_FILE} -Dpackaging=${PKG_TYPE} ${CLASSIFER_OPTION} ${POM_OPTION}"
    $CMD || exit $?
}

# Main
while getopts "p:r:v:b:s:h" opt; do
    case $opt in
        p) PRODUCT=$OPTARG;;
        r) RELEASE=$OPTARG;;
        v) VERSION=$OPTARG;;
        b) BLD_NUM=$OPTARG;;
        s) SUFFIX=$OPTARG;;
        h|?) usage
           exit 0;;
        *) echo "Invalid argument $opt"
           usage
           exit 1;;
    esac
done

if [[ -z ${PRODUCT} || -z ${RELEASE} || -z ${VERSION} || -z ${BLD_NUM} ]]; then
    usage
    exit 1
fi

if [[ ! ${PUBLISH_USERNAME} ]] || [[ ! ${PUBLISH_PASSWORD} ]]; then
    echo "Missing required environment vars: PUBLISH_PASSWORD, PUBLISH_PASSWORD"
    exit 1
fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
if [[ ! -f ${SCRIPT_DIR}/settings.xml ]]; then
    echo "Missing required maven's settings.xml file!"
    exit 1
fi

if [[ -n ${SUFFIX} ]]; then
    VERSION=${VERSION}-${SUFFIX}
fi

INTERNAL_MAVEN_URL="http://proget.build.couchbase.com/maven2/internalmaven/com/couchbase/lite"
GROUPID='com.couchbase.lite'
POM_FILE='default-pom.xml'

case ${PRODUCT} in
    couchbase-lite-android|couchbase-lite-android-ktx)
        PUBLISH_NAMES="${PRODUCT}"
        PUBLISH_URL="https://oss.sonatype.org/service/local/staging/deploy/maven2/"
        REPOSITORY_ID="ossrh"
        PUBLISH_LIST="aar javadoc javasrc"
        ;;
    couchbase-lite-android-ee|couchbase-lite-android-ee-ktx)
        PUBLISH_NAMES="${PRODUCT}"
        PUBLISH_URL="https://mobile.maven.couchbase.com/maven2/dev"
        REPOSITORY_ID="releases"
        PUBLISH_LIST="aar javadoc javasrc"
        ;;
    couchbase-lite-android-vector-search)
        PUBLISH_NAMES="${PRODUCT}-arm64 ${PRODUCT}-x86_64"
        PUBLISH_URL="https://mobile.maven.couchbase.com/maven2/dev"
        REPOSITORY_ID="releases"
        PUBLISH_LIST="aar"
        ;;
    *)
        echo "Unknown Product: ${PRODUCT}"
        exit 1
        ;;
esac

# Publish *.aar, *.jar, *.pom
for PUBLISH_NAME in ${PUBLISH_NAMES}; do
    # Update pom file with release version
    pom_file="${PUBLISH_NAME}-${RELEASE}-${BLD_NUM}.pom"
    echo "Downloading ${pom_file}..."
    curl -f -O ${INTERNAL_MAVEN_URL}/${PUBLISH_NAME}/${RELEASE}-${BLD_NUM}/${pom_file} ||  exit 1
    update_version

    aar="${PUBLISH_NAME}-${RELEASE}-${BLD_NUM}.aar"
    javadoc="${PUBLISH_NAME}-${RELEASE}-${BLD_NUM}-javadoc.jar"
    javasrc="${PUBLISH_NAME}-${RELEASE}-${BLD_NUM}-sources.jar"
    for file in ${PUBLISH_LIST}; do
        url=${INTERNAL_MAVEN_URL}/${PUBLISH_NAME}/${RELEASE}-${BLD_NUM}/${!file}
        echo "Downloading ${url}..."
        curl -f -O ${url} ||  exit 1
        echo "Uploading ${file}..."
        if [[ ${file} == "aar" ]]; then
            maven_deploy ${aar} 'aar' ''
        else
            maven_deploy ${!file} 'jar' ${file}
        fi
    done
    rm -f *.jar *.pom *.aar
done
