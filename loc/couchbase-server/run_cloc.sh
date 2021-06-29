#!/bin/bash -e

RELEASE=$1
TIMESTAMP=$2

shopt -s extglob

# The TAF project isn't in the manifest, so we need to use a few heuristics
# to check out the code. First, clone the project into a new "qe" subdir.
mkdir -p qe
pushd qe
git clone git://github.com/couchbaselabs/TAF
cd TAF

# If TAF has a git branch named after the RELEASE, check that out; otherwise
# use master
if [ ! -z "$(git ls-remote --heads origin ${RELEASE})" ]; then
    git checkout -B ${RELEASE} --track origin/${RELEASE}
fi

# Now check out the most recent commit that is older than the timestamp of
# the build itself
git checkout $(git rev-list -1 --before="${TIMESTAMP}" HEAD)

# Remove .git dir to not throw off cloc
rm -rf .git

popd

# Testrunner+TAF report
mv testrunner qe
pushd qe

echo @@@@@@@@@@@@@@@@@@@@@@@@@
echo "   TESTRUNNER + TAF"
echo @@@@@@@@@@@@@@@@@@@@@@@@@

cloc --quiet .

echo
echo

popd

# Prune a few things we don't want to count
rm -rf benchmark googletest qe

rm -rf platform/external
rm -rf third_party

# Third-party go code, including Bleve
rm -rf godeps/src/golang.org
rm -rf godeps/src/github.com/!(couchbase|couchbaselabs)

# Anything under goproj is presumed to be necessary to count.
# However, some things in goproj are ALSO mapped elsewhere due
# to Go modules transition. So let's prune those.
for project in *; do
    oldgodir="goproj/src/github.com/couchbase/${project}"
    if [ -d "${oldgodir}" ]; then
        echo "Removing double-mapped project ${oldgodir}"
        rm -rf ${oldgodir}
    fi
done

# Third-party AsterixDB code
rm -rf analytics/asterixdb

# test data
rm -rf goproj/src/github.com/couchbase/query/data/sampledb
rm -rf goproj/src/github.com/couchbase/docloader/examples
rm -rf goproj/src/github.com/couchbase/indexing/secondary/docs

# Ejecta
rm -rf cbbuild/tools/iOS

# rebar
rm -f tlm/cmake/Modules/rebar

# Sample data, testing code, etc
rm -rf analytics/cbas/cbas-test
find . -type d -name test -print0 | xargs -0 rm -rf
find . -type d -name testdata -print0 | xargs -0 rm -rf
find . -type d -name gtest -print0 | xargs -0 rm -rf
find . -type d -name testing -print0 | xargs -0 rm -rf
find . -type d -name \*tests -print0 | xargs -0 rm -rf
find . -type d -name \*test -print0 | xargs -0 rm -rf
find . -type d -name data -print0 | xargs -0 rm -rf
find . -type d -name docs -print0 | xargs -0 rm -rf
find . -type d -name examples -print0 | xargs -0 rm -rf
find . -type d -name samples -print0 | xargs -0 rm -rf
find . -type d -name benchmarks -print0 | xargs -0 rm -rf

echo @@@@@@@@@@@@@@@@@@@@@@@@@
echo "couchbase-server ${RELEASE}"
echo @@@@@@@@@@@@@@@@@@@@@@@@@

cloc --quiet .
