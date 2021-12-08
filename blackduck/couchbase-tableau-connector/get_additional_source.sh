#!/bin/bash -ex

#dependency:go-offline target does not work here since dependent jdbc connector is part of the build.
#Hence, need to do a full build to actually get all the dependencies.

JDK_VERSION=11.0.9+11
MAVEN_VERSION=3.5.2-cb6
mkdir deps
pushd deps
curl -L -o cbdep http://downloads.build.couchbase.com/cbdep/cbdep.linux
chmod 755 cbdep

./cbdep install openjdk ${JDK_VERSION} -d .
./cbdep install maven ${MAVEN_VERSION} -d .
export PATH=$(pwd)/maven-${MAVEN_VERSION}/bin:$(pwd)/openjdk-${JDK_VERSION}/bin:$PATH
export JAVA_HOME=$(pwd)/openjdk-${JDK_VERSION}
popd

mvn -B install -DskipTests -Dpython.path=$(which python3) -f cbtaco/pom.xml

#Get additional dependencie from Couchase JVM Clients
#Only core-io-deps is used by tabealu jdbc connector, hence the rest is removed.
COREIO_VERSION=$(cat cbtaco/cbas/pom.xml | grep "<couchbase-coreio.version>" |awk -F "<|>" '{print $3}')
pushd cbtaco/couchbase-jdbc-driver
git clone https://github.com/couchbase/couchbase-jvm-clients
pushd couchbase-jvm-clients
git checkout core-io-${COREIO_VERSION}
cd core-io-deps
mvn -B install -DskipTests
popd
mv couchbase-jvm-clients/core-io-deps .
rm -rf couchbase-jvm-clients
popd
