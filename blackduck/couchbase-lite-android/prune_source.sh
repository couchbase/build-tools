#!/bin/bash -ex

#clean up unnecessary source directories
for i in fleece Docs doc test tests docs googletest third_party _obsolete upgradetest cbbuild; do
     find . -type d -name $i | xargs rm -rf
done
