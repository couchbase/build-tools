#!/bin/bash -ex

#clean up unnecessary source directories
for i in fleece Docs doc test tests docs googletest third_party _obsolete upgradetest cbbuild; do
     find . -type d -name $i | xargs rm -rf
done

rm -rf cbl-java/ee/java
rm -rf cbl-java/ce/java
rm -rf cbl-java/common/java
