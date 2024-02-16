#!/bin/bash -ex
git clone ssh://git@github.com/couchbaselabs/capella-data-studio
echo
echo "Scanning revision:"
git -C capella-data-studio log -1
echo
echo
