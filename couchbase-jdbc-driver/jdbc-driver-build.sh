#!/bin/bash -ex

# Production build of the Couchbase JDBC driver, run by the
# couchbase-jdbc-driver-build job for each build-from-manifest build.
#
# Each manifest under couchbase-jdbc-driver/ in the manifest repo builds ONE
# driver flavor, named by <annotation name="FLAVOR"> on its "build" project:
#   couchbase-operational-insights -> couchbase-operational-insights-jdbc-driver
#   couchbase-analytics            -> couchbase-analytics-jdbc-driver
# and that manifest's VERSION annotation is the flavor's release version.
#
# The Maven version is stamped as the plain ${VERSION}, never ${VERSION}-${BLD_NUM}
# or a -SNAPSHOT: the driver reports its jar's Implementation-Version from
# getDriverVersion(), so the jar a release promotes must already carry the
# release version. BLD_NUM goes into the dist file names, and is passed as
# -Dbld.num for the jar manifest.
#
# Code-signing is opt-in, because every DigiCert signature is billed. A build
# signs the driver jar only when its manifest carries
#   <annotation name="SIGN" value="true"/>
# on the "build" project; absent or "false" builds unsigned. The annotation is
# part of the build manifest, so a rebuild of a signed build signs again.
# Signing changes the jar's bytes, so release candidates should be built
# signed: the build that ships has to be the one that was tested.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../utilities/shell-utils.sh"

function usage {
    echo "Requires PRODUCT, RELEASE, VERSION and BLD_NUM in the environment"
    exit 1
}

chk_set PRODUCT
chk_set RELEASE
chk_set VERSION
chk_set BLD_NUM

JDK_VERSION=21.0.11+10
MAVEN_VERSION=3.9.11
VERSIONS_PLUGIN=org.codehaus.mojo:versions-maven-plugin:2.18.0

SRC_DIR=couchbase-jdbc-driver

rm -rf deps && mkdir deps
rm -rf dist && mkdir dist

pushd deps
cbdep install openjdk ${JDK_VERSION} -d .
cbdep install mvn ${MAVEN_VERSION} -d .
export JAVA_HOME=$(pwd)/openjdk-${JDK_VERSION}
export PATH=$(pwd)/mvn-${MAVEN_VERSION}/bin:${JAVA_HOME}/bin:$PATH
popd

FLAVOR=$(annot_from_manifest FLAVOR)
[ -n "${FLAVOR}" ] || error "no FLAVOR annotation in the build manifest"

SIGN=$(annot_from_manifest SIGN false)
case "${SIGN}" in
    true) SIGN=true ;;
    false) SIGN=false ;;
    *) error "SIGN annotation must be true or false, not '${SIGN}'" ;;
esac

MODULE=${FLAVOR}-jdbc-driver
[ -f "${SRC_DIR}/${MODULE}/pom.xml" ] || error "flavor '${FLAVOR}' has no module ${SRC_DIR}/${MODULE}"

# Selecting the flavor profile keeps the other flavor out of the reactor;
# Maven only warns about an unknown -P, which the module check above covers
MVN="mvn -B -f ${SRC_DIR}/pom.xml -P flavor-${FLAVOR} -Dmaven.repo.local=$(pwd)/.repository"

# The module must be at this manifest's VERSION, as a -SNAPSHOT during
# development or bare once its release commit lands. Anything else means the
# manifest's VERSION annotation and the POM have drifted apart.
POM_VERSION=$(${MVN} -q -pl ${MODULE} help:evaluate -Dexpression=project.version -DforceStdout)
if [ "${POM_VERSION}" != "${VERSION}-SNAPSHOT" ] && [ "${POM_VERSION}" != "${VERSION}" ]; then
    error "${MODULE} is at ${POM_VERSION}, but the manifest is building ${VERSION}"
fi

# With the flavor profile the reactor is just the parent and this module, so
# this stamps both; the parent is flattened out of the module's published POM
if ${SIGN}; then
    # DigiCert Software Trust Manager settings come from the environment; the
    # API key and client cert password are read from SM_CONFIG_FILE
    : "${SM_HOST:?not set}"
    : "${SM_KEYPAIR_ALIAS:?not set}"
    : "${SM_CLIENT_CERT_FILE:?not set}"
    : "${SM_CONFIG_FILE:?not set}"
    set +x  # don't echo the credentials under 'set -x'
    export SM_API_KEY=$(sed -n 's/^SM_API_KEY=//p' "${SM_CONFIG_FILE}" | tr -d '\r')
    export SM_CLIENT_CERT_PASSWORD=$(sed -n 's/^SM_CLIENT_CERT_PASSWORD=//p' "${SM_CONFIG_FILE}" | tr -d '\r')
    : "${SM_API_KEY:?missing from SM_CONFIG_FILE}"
    : "${SM_CLIENT_CERT_PASSWORD:?missing from SM_CONFIG_FILE}"
    set -x
    : "${DIGICERT_JCE_DIR:?is not set; agent image lacks the DigiCert JCE jars}"
    shopt -s nullglob
    jce_jars=("${DIGICERT_JCE_DIR}"/digicert-jce-*.jar)
    bcprov_jars=("${DIGICERT_JCE_DIR}"/bcprov-*.jar)
    shopt -u nullglob
    if [ "${#jce_jars[@]}" -ne 1 ] || [ "${#bcprov_jars[@]}" -ne 1 ]; then
        error "expected one digicert-jce-*.jar and one bcprov-*.jar in ${DIGICERT_JCE_DIR}"
    fi
    JCE_CP="${jce_jars[0]}:${bcprov_jars[0]}"
    DIGICERT_TSA=http://timestamp.digicert.com

    # Check the signing cert is still valid BEFORE building -- fail fast, and
    # don't sign with an expired cert
    VALID_DATE=$(
        keytool -J-cp -J"${JCE_CP}" -list -v -keystore NONE -storetype DIGICERT \
            -storepass changeit -providerClass com.digicert.jce.Provider \
            -alias "${SM_KEYPAIR_ALIAS}" |
        grep '^Valid' | head -1 | sed 's/.*until: //'
    )
    [ -n "${VALID_DATE}" ] || error "could not read signing certificate '${SM_KEYPAIR_ALIAS}' (see keytool output above)"
    if [ $(date +%s) -gt $(date -d "${VALID_DATE}" +%s) ]; then
        error "signing certificate expired on ${VALID_DATE}"
    fi
fi

${MVN} -q ${VERSIONS_PLUGIN}:set \
    -DgroupId=com.couchbase.client \
    -DartifactId=${MODULE} \
    -DoldVersion='*' \
    -DnewVersion=${VERSION} \
    -DprocessAllModules=true \
    -DgenerateBackupPoms=false

${MVN} -Dbld.num=${BLD_NUM} -DskipTests clean install

# Publish the Maven artifacts to latestbuilds under ${VERSION}-${BLD_NUM}
# names; their contents (and the POM's <version>) stay ${VERSION}
TARGET=${SRC_DIR}/${MODULE}/target
for classifier in "" -sources -javadoc; do
    cp -p "${TARGET}/${MODULE}-${VERSION}${classifier}.jar" \
        "dist/${MODULE}-${VERSION}-${BLD_NUM}${classifier}.jar"
done
cp -p "${SRC_DIR}/${MODULE}/.flattened-pom.xml" \
    "dist/${MODULE}-${VERSION}-${BLD_NUM}.pom"

# One signature per build: the driver jar only, since the -sources and
# -javadoc jars hold no code that runs
if ${SIGN}; then
    DRIVER_JAR="dist/${MODULE}-${VERSION}-${BLD_NUM}.jar"
    jarsigner -J-cp -J"${JCE_CP}" -keystore NONE -storetype DIGICERT \
        -storepass changeit -providerClass com.digicert.jce.Provider \
        -tsa "${DIGICERT_TSA}" "${DRIVER_JAR}" "${SM_KEYPAIR_ALIAS}"
    jarsigner -verify "${DRIVER_JAR}"
fi
