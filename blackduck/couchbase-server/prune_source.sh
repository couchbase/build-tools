#!/bin/bash -ex

RELEASE=$1

shopt -s extglob

# NPM-related stuff - see CBD-3365

if [ "$RELEASE" = "mad-hatter" ]; then
    # Can't scan package.json files with NPM detector unless we also
    # have package-lock.json, which we don't in mad-hatter, so...
    rm ns_server/priv/public/ui/package.json
    rm goproj/src/github.com/couchbase/cbgt/rest/static/lib/angular-bootstrap/package.json
    rm goproj/src/github.com/couchbase/cbgt/rest/static/lib/angular-route/package.json
    rm goproj/src/github.com/couchbase/cbgt/rest/static/lib/angular/package.json
else
    # Most of this stuff is npm-generated "compiled" code; we ONLY want
    # to scan the npm package.json/package-lock.json files
    mv ns_server/priv/public/ui/package*.json ns_server/priv
    rm -rf ns_server/priv/public

    for pkg in angular-bootstrap angular-route angular; do
        rm -rf goproj/src/github.com/couchbase/cbgt/rest/static/lib/${pkg}/!(package*.json)
    done
fi

# Server doesn't use asterix's dashboard, so prune that
rm analytics/asterixdb/asterixdb/asterix-dashboard/src/node/package.json

# Server doesn't use any of bleve-mapping-ui's NPM components, so eliminate them
rm -rf godeps/src/github.com/blevesearch/bleve-mapping-ui/bower_components

# END NPM-related stuff

# cleanup unwanted stuff - test files, build scripts, etc.
rm -rf testrunner
rm -rf cbbuild
rm -rf goproj/src/github.com/couchbase/query/data/sampledb
rm -rf goproj/src/github.com/couchbase/docloader/examples
rm -rf goproj/src/github.com/couchbase/indexing/secondary/docs
rm -f tlm/cmake/Modules/rebar

# General-purpose removal of test data, examples, docs, etc.
find . -name analytics -prune -o -type d -name test\* -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name testdata -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name gtest -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name testing -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name \*tests -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name data -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name docs -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name example -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name examples -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name samples -print0 | xargs -0 rm -rf
find . -name analytics -prune -o -type d -name benchmarks -print0 | xargs -0 rm -rf

# godeps-specific pruning (hopefully eliminated after switching entirely to Go modules)
rm -rf godeps/src/golang.org/x/tools/cmd/heapview/client

# Remove all msvc, vcs* window projects
WIN='example *msvc* *vcproj* *vcxproj* visual vstudio dot_net_example example csharp vc7ide'
for windir in ${WIN}; do
    find . -name analytics -prune -o -type d -name "$windir" -print0 | xargs -0 rm -rf
done

# cbdeps-specific pruning
pushd thirdparty-src/deps

rm -rf erlang/lib/*test*
rm -rf v8/src/debug
rm -rf v8/tools

rm -rf boost/more

rm -rf openssl/external/perl

# flatbuffers implementations we don't care about
pushd flatbuffers
rm -rf android dart go grpc java js lobster lua net php python reflection rust appveyor.yml composer.json package.json pom.xml
popd

# Build-time only tool
rm -rf maven

# We don't actually ship with this library enabled
rm -rf rocksdb

popd
