#!/bin/bash -ex

#clean up unnecessary source directories
for i in fleece Docs doc test tests docs googletest third_party; do
     find . -type d -name $i | xargs rm -rf
done

#set local.properties for gradle
echo "LINUX_LIBCXX_INCDIR=${LIBCXX_INCDIR}/c++/v1" > local.properties
echo "LINUX_LIBCXX_LIBDIR=${LIBCXX_LIBDIR}" >> local.properties
