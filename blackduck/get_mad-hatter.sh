#!/bin/bash -ex

MANIFEST=$1

# Check out the main source code
repo init -u git://github.com/couchbase/manifest -g all -m couchbase-server/${MANIFEST}
repo sync --jobs=6

# Eliminate Analytics Java code - this is scanned via the binary jar repo
rm -rf analytics

# Clone cbdeps (really need to clean this up)
mkdir cbdeps
cd cbdeps
git clone git://github.com/couchbasedeps/breakpad -b 20160926-couchbase &
git clone git://github.com/couchbasedeps/curl -b curl-7_60_0 &
git clone git://github.com/couchbasedeps/erlang -b OTP-20.3.8.11 &
git clone git://github.com/couchbasedeps/flatbuffers -b v1.10.0 &
git clone git://github.com/couchbasedeps/icu4c -b r59.1 &
git clone git://github.com/couchbasedeps/jemalloc -b stable-4 &
git clone git://github.com/couchbasedeps/json -b v3.1.2 &
git clone git://github.com/couchbasedeps/libevent -b release-2.1.8-stable-cb &
git clone git://github.com/couchbasedeps/python-snappy &
wait
(cd python-snappy && git checkout c97d633)
git clone git://github.com/couchbasedeps/snappy -b 1.1.1 &
git clone git://github.com/couchbasedeps/v8 -b 5.9.223 &
git clone git://github.com/couchbasedeps/flex &
git clone git://github.com/couchbasedeps/libuv -b v1.20.3 &
git clone git://github.com/couchbasedeps/lz4 -b v1.8.0 &
git clone git://github.com/couchbasedeps/numactl -b v2.0.11 &
git clone git://github.com/couchbasedeps/rocksdb -b v5.12.5 &
git clone git://github.com/couchbasedeps/openssl -b OpenSSL_1_0_2k &
git clone git://github.com/couchbasedeps/zlib -b v1.2.11 &
git clone git://github.com/boostorg/boost -b boost-1.67.0
wait

# cbdeps-specific pruning

rm -rf erlang/lib/*test*

# extra libs in boost-1.67.0
for i in asio fusion geometry hana phoenix spirit typeof; do
    rm -rf boost/libs/$i
done

# tree-sitter, gyp, ngyp
rm -rf breakpad/src/tools/gyp
rm -rf v8/tools/gyp
rm -rf v8/build
rm -rf icu4c/win_binary
(cd v8 && rm -rf third_party/binutils/ third_party/icu/ third_party/llvm-build/ buildtools/ test)

# Prune things to fit in our 1GB source code limit
cd ..
find . -type d -name .git -print0 | xargs -0 rm -rf
rm -rf .repo

# cleanup unwanted stuff
rm -rf testrunner
rm -rf goproj/src/github.com/couchbase/query/data/sampledb
rm -rf goproj/src/github.com/couchbase/docloader/examples
rm -rf goproj/src/github.com/couchbase/indexing/secondary/docs

# Ejecta
rm -rf cbbuild/tools/iOS

# rebar
rm -f tlm/cmake/Modules/rebar

# Sample data, testing code, etc
rm -rf analytics/asterixdb/asterixdb/asterix-examples
rm -rf analytics/asterixdb/asterixdb/asterix-app/data
rm -rf analytics/cbas/cbas-test
find . -type d -name test -print0 | xargs -0 rm -rf
find . -type d -name testdata -print0 | xargs -0 rm -rf
find . -type d -name gtest -print0 | xargs -0 rm -rf
find . -type d -name testing -print0 | xargs -0 rm -rf
find . -type d -name \*tests -print0 | xargs -0 rm -rf
find . -type d -name data -print0 | xargs -0 rm -rf
find . -type d -name docs -print0 | xargs -0 rm -rf
find . -type d -name examples -print0 | xargs -0 rm -rf
find . -type d -name samples -print0 | xargs -0 rm -rf
find . -type d -name benchmarks -print0 | xargs -0 rm -rf
