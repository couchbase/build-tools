#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com:couchbaselabs/analytics-dotnet-client.git
pushd analytics-dotnet-client
if git rev-parse --verify --quiet $VERSION >& /dev/null
then
    echo "Tag $VERSION exists, checking it out"
    git checkout $VERSION
else
    echo "No tag $VERSION, assuming master"
fi

rm -rf analytics-dotnet-client/tests
rm -rf analytics-dotnet-client/fit

popd