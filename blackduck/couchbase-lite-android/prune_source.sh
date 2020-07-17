#!/bin/bash -ex

# We only scan cbl-java/ee/android, so only need to prune under there
cd cbl-java/ee/android

#couchbase-lite-core is attached as a sub-project, no need to scan
for i in couchbase-lite-core-EE couchbase-lite-core; do
   find . -type d -name $i | xargs rm -rf
done
