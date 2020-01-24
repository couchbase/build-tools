#!/bin/bash

RELEASE=$1

shopt -s extglob

# Testrunner report
pushd testrunner
echo @@@@@@@@@@@@@@@@@@@@@@@@@
echo "     TESTRUNNER"
echo @@@@@@@@@@@@@@@@@@@@@@@@@

cloc --quiet .

echo
echo

popd
rm -rf benchmark googletest testrunner

rm -rf platform/external
rm -rf third_party

# Third-party go code, including Bleve
rm -rf godeps/src/golang.org
rm -rf godeps/src/github.com/!(couchbase)

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
