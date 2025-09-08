#!/bin/bash -ex

echo "Download dependent tools: maven and jdk"

#When set JDK_HOME to system installed, it didn't seem to work somehow.
#Download via cbdep so we have control over which version to use.
#Download maven (3.3.9+ should work)

JDK_VERSION=11.0.20+8
MAVEN_VERSION=3.9.11
PYTHON_VERSION=3.11.13

rm -rf deps && mkdir deps
rm -rf dist && mkdir dist

pushd deps
cbdep install openjdk ${JDK_VERSION} -d .
cbdep install mvn ${MAVEN_VERSION} -d .
export PATH=$(pwd)/mvn-${MAVEN_VERSION}/bin:$(pwd)/openjdk-${JDK_VERSION}/bin:$PATH
export JAVA_HOME=$(pwd)/openjdk-${JDK_VERSION}

# Also create a uv-managed python venv for tableau-connector-sdk
uv venv --python ${PYTHON_VERSION} --managed-python python-${PYTHON_VERSION}
export PY_EXE=$(pwd)/python-${PYTHON_VERSION}/bin/python3

popd

#Call maven target to replace the *-SNAPSHOT version with ${VERSION} in the pom

mvn -B versions:set \
    -DnewVersion=${VERSION} \
    -DgenerateBackupPoms=false \
    -f cbtaco/pom.xml

#Call maven target to generate artifacts
#DIGICERT_PASSWORD is an environment variable injected into jenkins job.

mvn -B install -DskipTests \
    -Dpython.path=${PY_EXE} \
    -DproductVersion=${VERSION}-${BLD_NUM} \
    -Djarsigner.arguments=-tsa,http://timestamp.digicert.com \
    -Dtaco.sign \
    -Djarsigner.alias=digicert \
    -Djarsigner.keystore=~/.digicert.jks \
    -Djarsigner.storepass=${DIGICERT_PASSWORD} \
    -f cbtaco/pom.xml

# Verify that the cert is still valid
VALID_DATE=$(
    keytool -list -keystore ~/.digicert.jks -storepass ${DIGICERT_PASSWORD} -v |
    grep '^Valid' | head -1 | sed 's/.*until: //'
)
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

#Copy over artifacts to dist dir so that they can be published

pushd dist
cp -p ../cbtaco/cbas/cbas-jdbc-taco/target/${PRODUCT}-${VERSION}-${BLD_NUM}.zip .
popd
