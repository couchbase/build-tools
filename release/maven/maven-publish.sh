#!/bin/bash
# Publish built packages from internal_maven to maven repo

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERNAL_MAVEN_URL="https://proget.sc.couchbase.com/maven2/internalmaven/com/couchbase/lite"
GROUPID='com.couchbase.lite'

function usage() {
    echo
    echo "$0 -p <product> -r <release> -v <version> -b <build-number> [-s <suffix>]"
    echo "where:"
    echo "  -p: product name: couchbase-lite-android, couchbase-lite-java, etc."
    echo "  -r: release branch: master, 1.5.0, etc."
    echo "  -v: version number: 3.2.0, etc."
    echo "  -b: build number: 128, etc."
    echo "  -s: version suffix, eg. 'MP1' or 'beta' [optional]"
    echo
}

function update_version() {
    echo "Stripping BLD_NUM from ${pom_file} \n"
    sed -i.bak "s#<version>${RELEASE}-${BLD_NUM}</version>#<version>${VERSION}</version>#" ${downloaded_pom} || exit 1
    mv ${downloaded_pom} ${pom_file}
    diff ${pom_file} ${downloaded_pom}.bak
}

function download_artifacts() {
    local publish_name="$1"
    local packaging="$2"  # aar or jar
    local include_docs="$3"  # true or false

    # original names (including BLD_NUM)
    downloaded_pom="${publish_name}-${RELEASE}-${BLD_NUM}.pom"
    downloaded_main="${publish_name}-${RELEASE}-${BLD_NUM}.${packaging}"
    pom_file="${publish_name}-${VERSION}.pom"
    main_file="${publish_name}-${VERSION}.${packaging}"

    # Download POM and update version
    echo "Downloading ${downloaded_pom}..."
    curl -f -O "${INTERNAL_MAVEN_URL}/${publish_name}/${RELEASE}-${BLD_NUM}/${downloaded_pom}" || exit 1
    update_version

    echo "Downloading ${downloaded_main} and renaming to ${main_file}..."
    curl -f -O "${INTERNAL_MAVEN_URL}/${publish_name}/${RELEASE}-${BLD_NUM}/${downloaded_main}"
    mv "${downloaded_main}" "${main_file}"

    # Download and rename sources/javadoc if requested
    if [[ "${include_docs}" == "true" ]]; then
        # original names (including BLD_NUM)
        downloaded_sources="${publish_name}-${RELEASE}-${BLD_NUM}-sources.jar"
        downloaded_javadoc="${publish_name}-${RELEASE}-${BLD_NUM}-javadoc.jar"
        sources_file="${publish_name}-${VERSION}-sources.jar"
        javadoc_file="${publish_name}-${VERSION}-javadoc.jar"

        echo "Downloading ${downloaded_sources} and renaming to ${sources_file}..."
        curl -f -O "${INTERNAL_MAVEN_URL}/${publish_name}/${RELEASE}-${BLD_NUM}/${downloaded_sources}" || exit 1
        mv "${downloaded_sources}" "${sources_file}"

        echo "Downloading ${downloaded_javadoc} and renaming to ${javadoc_file}..."
        curl -f -O "${INTERNAL_MAVEN_URL}/${publish_name}/${RELEASE}-${BLD_NUM}/${downloaded_javadoc}"
        mv "${downloaded_javadoc}" "${javadoc_file}"
    fi
    echo "All artifacts downloaded and renamed successfully"
}

function sonatype_api_publish() {
    local publish_name="$1"
    local packaging="$2"  # aar or jar

    # ${pom_file}, ${main_file}, ${sources_file}, ${javadoc_file}
    # are set in download_artifacts
    echo "Signing and creating checksums for ${publish_name}..."
    gpg --no-tty --armor --detach-sign "${main_file}"
    gpg --verify "${main_file}".asc "${main_file}"
    for file in "${pom_file}" "${main_file}" "${sources_file}" "${javadoc_file}"; do
        gpg --no-tty --armor --detach-sign "${file}"
        gpg --verify "${file}".asc "${file}"
        md5sum "${file}" | cut -d' ' -f1 > "${file}.md5"
        sha1sum "${file}" | cut -d' ' -f1 > "${file}.sha1"
    done

    # Create directory and organize files
    local target_dir="com/couchbase/lite/${publish_name}/${VERSION}/"
    mkdir -p "${target_dir}"

    # Move files using consistent global variables
    mv "${pom_file}"* "${target_dir}"
    mv "${main_file}"* "${target_dir}"
    mv "${sources_file}"* "${target_dir}"
    mv "${javadoc_file}"* "${target_dir}"
    zip -r "${publish_name}-${VERSION}-bundle.zip" com/

    echo "Uploading to central.sonatype.com..."
    authbase64=$(printf "${PUBLISH_USERNAME}:${PUBLISH_PASSWORD}" | base64)
    curl --request POST \
        --header "Authorization: Basic ${authbase64}" \
        --form bundle=@${publish_name}-${VERSION}-bundle.zip \
        https://central.sonatype.com/api/v1/publisher/upload
    # cleanup after publishing
    rm -rf com
    rm -f *.zip
}

function mvn_deploy_artifact() {
    local publish_name="$1"
    local packaging="$2"  # aar or jar
    local include_docs="$3"  # true or false

    echo "Deploying ${publish_name} to ${PUBLISH_URL}..."

    # ${pom_file}, ${main_file}, ${sources_file}, ${javadoc_file}
    # are set in download_artifacts
    local mvn_cmd="mvn --settings ./settings.xml"
    mvn_cmd+=" -Dpublish.username=${PUBLISH_USERNAME}"
    mvn_cmd+=" -Dpublish.password=${PUBLISH_PASSWORD}"
    mvn_cmd+=" -DrepositoryId=${REPOSITORY_ID}"
    mvn_cmd+=" -Durl=${PUBLISH_URL}"
    mvn_cmd+=" gpg:sign-and-deploy-file"
    mvn_cmd+=" -DgroupId=${GROUPID}"
    mvn_cmd+=" -DartifactId=${publish_name}"
    mvn_cmd+=" -Dversion=${VERSION}"
    mvn_cmd+=" -Dfile=${main_file}"
    mvn_cmd+=" -DpomFile=${pom_file}"
    mvn_cmd+=" -Dpackaging=${packaging}"

    # Add sources and javadoc if available (uses global variables)
    if [[ "${include_docs}" == "true" ]]; then
        mvn_cmd+=" -Dsources=${sources_file}"
        mvn_cmd+=" -Djavadoc=${javadoc_file}"
    fi

    echo "Executing Maven deployment command..."
    $mvn_cmd || exit $?

    # Cleanup after publishing
    rm -f ./*.jar ./*.pom ./*.aar ./*.asc
}

# Parse command line arguments
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

# Validate settings file
if [[ ! -f "${SCRIPT_DIR}/settings.xml" ]]; then
    echo "Error: Missing required maven's settings.xml file!"
    exit 1
fi

# Add suffix to version if provided
if [[ -n "${SUFFIX}" ]]; then
    VERSION="${VERSION}-${SUFFIX}"
fi

echo "Publishing ${PRODUCT} ${VERSION} (${RELEASE}-${BLD_NUM})"

# Configure product-specific settings and deploy
case "${PRODUCT}" in
    couchbase-lite-android|couchbase-lite-android-ktx)
        PUBLISH_URL="https://central.sonatype.com/api/v1/publisher/upload"
        REPOSITORY_ID="central"
        download_artifacts "${PRODUCT}" "aar" "true"
        sonatype_api_publish "${PRODUCT}" "aar"
        ;;
    couchbase-lite-android-ee|couchbase-lite-android-ee-ktx)
        PUBLISH_URL="https://mobile.maven.couchbase.com/maven2/dev"
        REPOSITORY_ID="releases"
        download_artifacts "${PRODUCT}" "aar" "true"
        mvn_deploy_artifact "${PRODUCT}" "aar" "true"
        ;;
    couchbase-lite-android-vector-search)
        PUBLISH_URL="https://mobile.maven.couchbase.com/maven2/dev"
        REPOSITORY_ID="releases"
        for arch in arm64 x86_64; do
            download_artifacts "${PRODUCT}-${arch}" "aar" "false"
            mvn_deploy_artifact "${PRODUCT}-${arch}" "aar" "false"
        done
        ;;
    couchbase-lite-java-vector-search)
        PUBLISH_URL="https://mobile.maven.couchbase.com/maven2/dev"
        REPOSITORY_ID="releases"
        download_artifacts "${PRODUCT}" "jar" "false"
        mvn_deploy_artifact "${PRODUCT}" "jar" "false"
        ;;
    couchbase-lite-java)
        PUBLISH_URL="https://central.sonatype.com/api/v1/publisher/upload"
        REPOSITORY_ID="central"
        download_artifacts "${PRODUCT}" "jar" "true"
        sonatype_api_publish "${PRODUCT}" "jar"
        ;;
    couchbase-lite-java-ee)
        PUBLISH_URL="https://mobile.maven.couchbase.com/maven2/dev"
        REPOSITORY_ID="releases"
        download_artifacts "${PRODUCT}" "jar" "true"
        mvn_deploy_artifact "${PRODUCT}" "jar" "true"
        ;;
    *)
        echo "Error: Unknown product: ${PRODUCT}"
        exit 1
        ;;
esac
