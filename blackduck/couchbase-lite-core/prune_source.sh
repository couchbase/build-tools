#!/bin/bash -ex

pwd

##remove LiteCore-iOS and libstemmer_c per CBD-3616
rm -rf couchbase-lite-core/Xcode/LiteCore-iOS/LiteCore-iOS

# cleanup unwanted stuff - test files, build scripts, etc.
for i in fleece Docs doc test tests docs googletest third_party cbbuild tlm libstemmer_c; do
     find . -type d -name $i | xargs rm -rf
done
