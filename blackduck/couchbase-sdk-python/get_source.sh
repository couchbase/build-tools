#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone git://github.com/couchbase/couchbase-python-client.git
pushd couchbase-python-client
if git rev-parse --verify --quiet $VERSION >& /dev/null
then
    echo "Tag $VERSION exists, checking it out"
    git checkout $VERSION
else
    echo "No tag $VERSION, assuming master"
    git checkout master
fi

# Now lets get the dependencies and store 'em locally.
# We have 2 sets of dependencies, 1 for development and
# a second for actual use.  I believe we don't need to
# worry about the development dependencies (like, for tests
# and builds and so forth
mkdir deps
pip3 download -r requirements.txt -d deps/
# At this point, all the requirements are in /deps.  They
# are all either .whl files (which are just zips), or a
# few are tar.gz.  So you can loop and extract, or perhaps
# blackduck can figure it out on its own.  Feel free to
# add .zip to the .whl files if that helps it detect
# stuff.
popd

# setup.py depends on packages from this, but that dooesn't
# appear to be documented in the source code anywhere. Just
# make sure it's available.
pip3 install -U sphinx
