#!/bin/bash -ex

pwd

# clean up unnecessary source and test directories
for i in cbbuild; do
   find . -type d -name $i | xargs rm -rf
done
