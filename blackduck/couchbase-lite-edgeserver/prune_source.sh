#!/bin/bash -ex

# clean up unnecessary source directories
for i in cbbuild build tests; do
   find . -type d -name $i | xargs rm -rf
done
