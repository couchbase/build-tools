#!/bin/bash -ex

#clean up unnecessary source directories
#couchbase-lite-core is attached as a sub-project, no need to scan
for i in cbbuild fleece gradle Docs doc test tests docs googletest third_party _obsolete VisualStudio dotzlib MYUtilities couchbase-lite-core-EE couchbase-lite-core; do
   find . -type d -name $i | xargs rm -rf
done
