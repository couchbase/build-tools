#!/bin/bash -ex

echo "Download dependent tools: maven, jdk and python"

#When set JDK_HOME to system installed, it didn't seem to work somehow.
#Download via cbdep so we have control over which version to use.
#Download maven (3.3.9+ should work)

JDK_VERSION=21.0.11+10
MAVEN_VERSION=3.9.11
PYTHON_VERSION=3.11.13

rm -rf deps && mkdir deps
rm -rf build
rm -rf dist && mkdir dist

pushd deps
cbdep install openjdk ${JDK_VERSION} -d .
cbdep install mvn ${MAVEN_VERSION} -d .
export JAVA_HOME=$(pwd)/openjdk-${JDK_VERSION}
export MVN_EXE=$(pwd)/mvn-${MAVEN_VERSION}/bin/mvn
export PATH=$(pwd)/mvn-${MAVEN_VERSION}/bin:${JAVA_HOME}/bin:$PATH

# Also create a uv-managed python venv for tableau-connector-sdk
uv venv --python ${PYTHON_VERSION} --managed-python python-${PYTHON_VERSION}
export PY_EXE=$(pwd)/python-${PYTHON_VERSION}/bin/python3

popd

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
    echo "ERROR! Expected one digicert-jce-*.jar and one bcprov-*.jar in ${DIGICERT_JCE_DIR}"
    exit 5
fi
JCE_CP="${jce_jars[0]}:${bcprov_jars[0]}"
DIGICERT_TSA=http://timestamp.digicert.com

# Verify the signing cert is still valid BEFORE building -- fail fast, and don't
# sign with an expired cert. keytool comes from the JDK installed above.
VALID_DATE=$(
    keytool -J-cp -J"${JCE_CP}" -list -v -keystore NONE -storetype DIGICERT \
        -storepass changeit -providerClass com.digicert.jce.Provider \
        -alias "${SM_KEYPAIR_ALIAS}" |
    grep '^Valid' | head -1 | sed 's/.*until: //'
)
if [ -z "${VALID_DATE}" ]; then
    echo "ERROR! Could not read signing certificate '${SM_KEYPAIR_ALIAS}' (see keytool output above)"
    exit 5
fi
VALID_TS=$(date -d "${VALID_DATE}" +%s)
NOW_TS=$(date +%s)
if [ $NOW_TS -gt $VALID_TS ]; then
    echo
    echo
    echo "ERROR! Signing certificate expired on ${VALID_DATE}!"
    echo
    echo
    exit 5
fi

# Drive the production build through CMake. -DPRODUCTION_BUILD=ON makes CMake:
#   1. Stamp versions: connector -> ${VERSION}; JDBC driver and the connector's
#      couchbase-jdbc.version property -> ${VERSION}.tableau (the driver is built
#      from source as part of this build).
#   2. mvn install the artifacts, and
#   3. DigiCert code-sign the .taco(s).
# Which SDK flavor(s) get built is decided by the repo manifest's <annotation
# name="SDK"> (analytics | operational | both); the script does not pin a flavor.
#
# Signing uses the DigiCert JCE provider jars in ${DIGICERT_JCE_DIR} and the SM_*
# variables above.
cmake -S . -B build \
    -DPRODUCTION_BUILD=ON \
    -DDIGICERT_ALIAS="${SM_KEYPAIR_ALIAS}" \
    -DDIGICERT_TSA="${DIGICERT_TSA}" \
    -DVERSION="${VERSION}" \
    -DBLD_NUM="${BLD_NUM}" \
    -DTACO_PYTHON="${PY_EXE}" \
    -DMAVEN_EXECUTABLE="${MVN_EXE}"

cmake --build build

#Copy the built connector zip to dist for publishing. Exactly one flavor is
#built per job (selected by the repo manifest's SDK annotation), and each
#flavor names its dist zip <flavor>-tableau-connector-${VERSION}-${BLD_NUM}.zip
#(see build.taco.assembly.name), so match that and guard against an unexpected
#second flavor rather than silently shipping the wrong one.

shopt -s nullglob
zips=(cbas/cbas-jdbc-taco/*/target/*-tableau-connector-${VERSION}-${BLD_NUM}.zip)
shopt -u nullglob
if [ "${#zips[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one *-tableau-connector-${VERSION}-${BLD_NUM}.zip, found ${#zips[@]}: ${zips[*]}"
    echo "(this job must build a single SDK flavor; check the manifest SDK annotation)"
    exit 6
fi
cp -p "${zips[0]}" dist/

# The build signs only the .taco; sign the bundled JDBC driver jar in the dist zip
dist_zip="dist/$(basename "${zips[0]}")"
rm -rf build/driver && mkdir build/driver
unzip -q "${dist_zip}" '*-jdbc-driver-*.jar' -d build/driver
shopt -s nullglob
drivers=(build/driver/*-jdbc-driver-*.jar)
shopt -u nullglob
if [ "${#drivers[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one *-jdbc-driver-*.jar in ${dist_zip}, found ${#drivers[@]}: ${drivers[*]}"
    exit 7
fi
jarsigner -J-cp -J"${JCE_CP}" -keystore NONE -storetype DIGICERT \
    -storepass changeit -providerClass com.digicert.jce.Provider \
    -tsa "${DIGICERT_TSA}" "${drivers[0]}" "${SM_KEYPAIR_ALIAS}"

# Swap the signed jar into the zip, keeping every entry's metadata
"${PY_EXE}" -I - "${dist_zip}" "${drivers[0]}" <<'EOF'
import os, sys, zipfile
zip_path, jar = sys.argv[1:]
tmp = zip_path + ".tmp"
with zipfile.ZipFile(zip_path) as src, zipfile.ZipFile(tmp, "w") as dst:
    for info in src.infolist():
        if info.filename == os.path.basename(jar):
            with open(jar, "rb") as f:
                dst.writestr(info, f.read())
        else:
            dst.writestr(info, src.read(info))
os.replace(tmp, zip_path)
EOF
