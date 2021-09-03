#!/bin/bash -ex

pwd

#According to readme in rust directory.  It is not shipped.
rm -rf couchbase-lite-c/bindings/rust

# cleanup unwanted stuff - test files, build scripts, etc.
for i in fleece Docs doc test tests docs googletest third_party cbbuild tlm libstemmer_c; do
     find . -type d -name $i | xargs rm -rf
done
