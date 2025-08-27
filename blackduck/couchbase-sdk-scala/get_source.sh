#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com/couchbase/couchbase-jvm-clients
pushd couchbase-jvm-clients

if [[ "$VERSION" == 1.* ]]
then
    TAG=scala-client-$VERSION
else
    TAG=$VERSION
fi

if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "$TAG exists, checking it out"
    git checkout $TAG
else
    echo "No $TAG tag or branch, assuming master"
fi

# The fit-performer packages are test-only and require a non-public
# jar, so they'll never be shipped; but their poms mess up the scans.
rm -rf *-fit-performer

# Black Duck needs either `mvn` on the PATH, or a `.mvnw` executable
# next to each `pom.xml`. We'd prefer not to do the former since it
# depends on us remembering to update Maven every so often. Since `mvnw`
# should be constant, just copy it everywhere.
for pom in $(find . -mindepth 2 -name pom.xml -print); do
    cp -v ./mvnw "$(dirname "$pom")"
done

# And now we actually need to build stuff for it to be found by the
# detector :( Use a custom local Maven repository per-product to ensure
# SNAPSHOT stuff doesn't cross-polinate.
export MAVEN_CONFIG="--batch-mode -Dmaven.repo.local=/home/couchbase/.m2/${PRODUCT}-repository -Dmaven.test.skip=true"
make install

popd
