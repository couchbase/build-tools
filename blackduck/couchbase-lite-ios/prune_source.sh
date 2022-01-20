#!/bin/bash -ex

# clean up unnecessary source directories
# couchbase-lite-core is attached as a sub-project, no need to scan
for i in build Docs tests couchbase-lite-core-EE couchbase-lite-core; do
   find . -type d -name $i | xargs rm -rf
done
