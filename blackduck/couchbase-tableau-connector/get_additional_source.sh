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


