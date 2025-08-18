#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

# current repo, do not remove:
# github.com/couchbase/couchbase-jvm-clients

if [[ "$VERSION" == 3.8.* ]]
then
    TAG=java-client-$VERSION
else
    TAG=$VERSION
fi

git clone https://github.com/couchbase/couchbase-jvm-clients
pushd couchbase-jvm-clients
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi

# The fit-performer packages are test-only and require a non-public
# jar, so they'll never be shipped; but their poms mess up the scans.
rm -rf *-fit-performer

make deps-only
# test-utils is in Makefile now and this line can be removed when we don't need to build older versions
./mvnw -B -DskipTests install -pl test-utils -am

# And now we actually need to build stuff for it to be found
# by the detector
./mvnw --batch-mode compile dependency:resolve

popd
