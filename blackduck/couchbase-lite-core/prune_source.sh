#!/bin/bash -ex

pwd

# cleanup unwanted stuff - test files, build scripts, etc.
for i in fleece Docs doc test tests docs googletest third_party cbbuild tlm; do
     find . -type d -name $i | xargs rm -rf
done
