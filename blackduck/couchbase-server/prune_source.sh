#!/bin/bash -ex

# Most of this stuff is npm-generated "compiled" code; we only want
# to scan the npm package.json/package-lock.json files
mv ns_server/priv/public/ui/package*.json ns_server/priv
rm -rf ns_server/priv/public

# cleanup unwanted stuff
rm -rf testrunner
rm -rf cbbuild
rm -rf goproj/src/github.com/couchbase/query/data/sampledb
rm -rf goproj/src/github.com/couchbase/docloader/examples
rm -rf goproj/src/github.com/couchbase/indexing/secondary/docs

# Ejecta
rm -rf cbbuild/tools/iOS

# rebar
rm -f tlm/cmake/Modules/rebar

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

# QQQ See if asterixdb can update to include package-lock.json
rm analytics/asterixdb/asterixdb/asterix-dashboard/src/node/package.json

# QQQ See if cbgt can update to include package-lock.json
rm goproj/src/github.com/couchbase/cbgt/rest/static/lib/angular-bootstrap/package.json
rm goproj/src/github.com/couchbase/cbgt/rest/static/lib/angular-route/package.json
rm goproj/src/github.com/couchbase/cbgt/rest/static/lib/angular/package.json

# QQQ See if bleve can update to include package-lock.json
rm godeps/src/github.com/blevesearch/bleve-mapping-ui/bower_components/angular/package.json
rm godeps/src/github.com/blevesearch/bleve-mapping-ui/bower_components/angular-bootstrap/package.json
rm godeps/src/github.com/blevesearch/bleve-mapping-ui/bower_components/bootstrap/package.json

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
