#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

BRANCH="master-${VERSION:0:3}"

git clone git://github.com/couchbaselabs/mobile-testkit
pushd mobile-testkit

if git rev-parse --verify --quiet $BRANCH >& /dev/null
then
    echo "Branch $BRANCH exists, checking it out"
    git checkout $BRANCH
else
    echo
    echo
    echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    echo "No branch $BRANCH, assuming master"
    echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    echo
    echo
fi
popd
