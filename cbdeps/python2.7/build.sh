#!/usr/bin/env bash
#
# This script assumes the following are installed on the system:
#   - git
#   - groff (soelim program needed)
#   - Python 2.(6|7) (along with header/devel files)
#   - pip (for above Python)
#   - virtualenv
#
#  Please ensure this is the case before running

set -e

virtualenv pybuild
. pybuild/bin/activate

# Build the portable Python
pip install zc.buildout
git clone https://github.com/Infinidat/relocatable-python.git
cd relocatable-python
buildout bootstrap
bin/buildout
bin/build

# Generate tarball
mv dist python2.7
tar zcf python-2.7-cb1-${PLATFORM}.tar.gz python2.7

deactivate
