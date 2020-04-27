#!/bin/bash -ex

pwd

#clean up unnecessary source directories
for i in fleece Docs doc test tests docs googletest third_party cbbuild; do
     find . -type d -name $i | xargs rm -rf
done

###get rid of android codes which are not used by java
rm -rf cbl-java/ee/android
rm -rf cbl-java/ce/android
rm -rf cbl-java/common/android

#set local.properties for gradle
echo "LINUX_LIBCXX_INCDIR=${LIBCXX_INCDIR}/c++/v1" > cbl-java/ee/java/local.properties
echo "LINUX_LIBCXX_LIBDIR=${LIBCXX_LIBDIR}" >> cbl-java/ee/java/local.properties

echo "LINUX_LIBCXX_INCDIR=${LIBCXX_INCDIR}/c++/v1" > cbl-java/ce/java/local.properties
echo "LINUX_LIBCXX_LIBDIR=${LIBCXX_LIBDIR}" >> cbl-java/ce/java/local.properties
