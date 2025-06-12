#!/bin/bash -ex

RELEASE=$1
VERSION=$2
BLD_NUM=$3
TOOLS_DIR=$4

shopt -s extglob

# NPM-related stuff - see CBD-3365

# Most of this stuff is npm-generated "compiled" code; we ONLY want
# to scan the npm package.json/package-lock.json files
mv ns_server/priv/public/ui/package*.json ns_server/priv
rm -rf ns_server/priv/public

# Server doesn't use asterix's dashboard, so prune that
rm analytics/asterixdb/asterixdb/asterix-dashboard/src/node/package.json

# This is build-time only, not shipped. (The directory name has changed over
# time.)
rm -f query-ui/query-ui/n1ql_parser/package.json
rm -f query-ui/query-ui/parser/antlr_runtime/package.json

# END NPM-related stuff

# Need to save any of these before deleting the rest of cbbuild
find cbbuild -name couchbase-server-black-duck-manifest.yaml -print0 | xargs -0 -I FILENAME cp FILENAME .

# cleanup unwanted stuff - test files, build scripts, etc.
rm -rf testrunner
rm -rf cbbuild
rm -rf goproj/src/github.com/couchbase/query/data/sampledb
rm -rf goproj/src/github.com/couchbase/docloader/examples
rm -rf goproj/src/github.com/couchbase/indexing/secondary/docs
find . -name rebar -print0 | xargs -0 rm -rf

# remove stuff in couchdbx-app except the BD manifest
find couchdbx-app -mindepth 1 -maxdepth 1 -name couchbase-server-black-duck-manifest.yaml -prune -or -print0 | xargs -0 rm -rf

# General-purpose removal of test data, examples, docs, etc.
find . -name analytics -prune -o -name regulator -prune -o -type d -name test\* -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name testdata -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name gtest -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name testing -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name \*tests -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -name backup -prune -o -name indexing -prune -o -type d -name data -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name docs -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name example -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name examples -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name samples -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name benchmarks -print0 | xargs -0 rm -rf

# Remove all msvc, vcs* window projects
WIN='example *msvc* *vcproj* *vcxproj* visual vstudio dot_net_example example csharp vc7ide'
for windir in ${WIN}; do
    find . -name analytics -prune -o -type d -name "$windir" -print0 | xargs -0 rm -rf
done
