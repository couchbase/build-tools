#!/bin/bash -ex

#set local.properties for gradle
echo "LINUX_LIBCXX_INCDIR=${LIBCXX_INCDIR}/c++/v1" > cbl-java/ee/java/local.properties
echo "LINUX_LIBCXX_LIBDIR=${LIBCXX_LIBDIR}" >> cbl-java/ee/java/local.properties

echo "LINUX_LIBCXX_INCDIR=${LIBCXX_INCDIR}/c++/v1" > cbl-java/ce/java/local.properties
echo "LINUX_LIBCXX_LIBDIR=${LIBCXX_LIBDIR}" >> cbl-java/ce/java/local.properties

# We only scan cbl-java/ee/java, so only need to prune under there
cd cbl-java/ee/java

#couchbase-lite-core is attached as a sub-project, no need to scan
for i in couchbase-lite-core-EE couchbase-lite-core; do
   find . -type d -name $i | xargs rm -rf
done
