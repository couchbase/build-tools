#!/bin/bash -ex

pwd

# cleanup unwanted stuff
# doc directory leads to wrong components and cves
find . -type d -name "doc" | xargs rm -rf
