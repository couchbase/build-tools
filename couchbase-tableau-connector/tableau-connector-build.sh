#!/bin/bash -ex

echo "Download dependent tools: maven and jdk"
#When set JDK_HOME to system installed, it didn't seem to work somehow.
#Download via cbdep so we have control over which version to use.
#Download maven (3.3.9+ should work)

CBDEP_VESION=1.1.2
JDK_VERSION=11.0.9+11
MAVEN_VERSION=3.5.2-cb6

mkdir deps
mkdir dist

pushd deps
curl https://packages.couchbase.com/cbdep/${CBDEP_VESION}/cbdep-${CBDEP_VESION}-linux-x86_64 -o cbdep
chmod +x cbdep
./cbdep install openjdk ${JDK_VERSION} -d .
./cbdep install maven ${MAVEN_VERSION} -d .
export PATH=$(pwd)/maven-${MAVEN_VERSION}/bin:$(pwd)/openjdk-${JDK_VERSION}/bin:$PATH
export JAVA_HOME=$(pwd)/openjdk-${JDK_VERSION}
popd

#Call maven target to replace the *-SNAPSHOT version with ${VERSION} in the pom

mvn -B versions:set \
    -DnewVersion=${VERSION} \
    -DgenerateBackupPoms=false

#Call maven target to generate artifacts
#DIGICERT_PASSWORD is an environment variable injected into jenkins job.

mvn -B install -DskipTests \
    -Dpython.path=$(which python3) \
    -DproductVersion=${VERSION}-${BLD_NUM} \
    -Djarsigner.arguments=-tsa,http://timestamp.digicert.com \
    -Dtaco.sign \
    -Djarsigner.alias=digicert \
    -Djarsigner.keystore=~/.digicert.jks \
    -Djarsigner.storepass=${DIGICERT_PASSWORD} \
    -f cbtaco/pom.xml

#Copy over artifacts to dist dir so that they can be published

pushd dist
cp -p ../cbtaco/cbas/cbas-jdbc-taco/target/${PRODUCT}-${VERSION}-${BLD_NUM}.zip .
popd

# Revert the update to the pom from *-SNAPSHOT to ${VERSION} version
git checkout .
