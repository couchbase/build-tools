#!/bin/bash -ex

MANIFEST=$1

# Check out the main source code
repo init -u git://github.com/couchbase/manifest -g all -m couchbase-server/${MANIFEST}

# Clone cbdeps (really need to clean this up)
mkdir cbdeps
cd cbdeps
git clone git://github.com/couchbasedeps/breakpad -b 20160926-couchbase
git clone git://github.com/couchbasedeps/curl -b curl-7_49_1
git clone git://github.com/couchbasedeps/erlang -b couchbase-watson
git clone git://github.com/couchbasedeps/flatbuffers -b v1.4.0
git clone git://github.com/couchbasedeps/icu4c -b r54.1
git clone git://github.com/couchbasedeps/jemalloc -b 4.3.1
git clone git://github.com/couchbasedeps/json -b v1.1.0
git clone git://github.com/couchbasedeps/libevent -b release-2.1.8-stable-cb
git clone git://github.com/couchbasedeps/python-snappy
(cd python-snappy && git checkout c97d633)
git clone git://github.com/couchbasedeps/snappy -b 1.1.1
git clone git://github.com/couchbasedeps/v8 -b 5.2-couchbase
for boost in assert config core detail functional intrusive math move mpl optional preprocessor static_assert throw_exception type_index type_traits utility variant
do
   git clone git://github.com/couchbasedeps/boost_${boost} -b boost-1.62.0
done

# cbdeps-specific pruning

# tree-sitter, gyp, ngyp
rm -rf breakpad/src/tools/gyp
rm -rf v8/tools/gyp
rm -rf icu4c/win_binary
(cd v8 && rm -rf third_party/binutils/ third_party/icu/ third_party/llvm-build/ buildtools/ test)

# Prune things to fit in our 1GB source code limit
cd ..
find . -type d -name .git -print0 | xargs -0 rm -rf
rm -rf .repo

# cleanup unwanted stuff

# Ejecta
rm -rf cbbuild/tools/iOS

# rebar
rm -f tlm/cmake/Modules/rebar

# Test data, etc
find . -type d -name test -print0 | xargs -0 rm -rf
find . -type d -name \*tests -print0 | xargs -0 rm -rf
find . -type d -name data -print0 | xargs -0 rm -rf
find . -type d -name docs -print0 | xargs -0 rm -rf
find . -type d -name examples -print0 | xargs -0 rm -rf
