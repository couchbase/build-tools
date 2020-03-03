#!/bin/bash -ex

#clean up unnecessary source directories
for i in fleece gradle Docs doc test tests docs googletest third_party _obsolete VisualStudio dotzlib MYUtilities; do
   find . -type d -name $i | xargs rm -rf
done
