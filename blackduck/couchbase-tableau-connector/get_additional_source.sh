#!/bin/bash -ex

MAVEN_VERSION=3.9.5
cbdep install -d ${WORKSPACE}/extra mvn ${MAVEN_VERSION}
mv ${WORKSPACE}/extra/mvn-${MAVEN_VERSION} ${WORKSPACE}/extra/mvn
export PATH=${WORKSPACE}/extra/mvn/bin:$PATH

mvn dependency:copy-dependencies \
    -DincludeScope=runtime \
    -f cbtaco/pom.xml

mv ${WORKSPACE}/src/cbtaco/cbas/cbas-jdbc-taco/target/dependency ${WORKSPACE}/src/cbtaco/.
pushd ${WORKSPACE}/src/cbtaco/dependency
for file in $(ls *.jar); do
  jar -xf $file
done
popd
