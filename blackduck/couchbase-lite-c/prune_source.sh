#!/bin/bash -ex

pwd

# According to readme in rust directory.  It is not shipped.
rm -rf couchbase-lite-c/bindings/rust

# clean up unnecessary source directories
# couchbase-lite-core is attached as a sub-project, no need to scan
for i in cbbuild tlm couchbase-lite-core-EE couchbase-lite-core; do
   find . -type d -name $i | xargs rm -rf
done
