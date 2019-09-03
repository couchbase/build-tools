#!/bin/bash

export PRODUCT=$1
export MANIFEST=$2

if [ -z "${WORKSPACE}" ]; then
    export WORKSPACE=`pwd`
fi

echo "Scan product: ${PRODUCT}"

# Get source from manifest file
mkdir -p scansrc
cd scansrc
repo init -u git://github.com/couchbase/manifest -g all -m ${PRODUCT}/${MANIFEST}
repo sync --jobs=6
repo forall -c 'git submodule update --init --recursive'

# Ignore source/directories
# added ignore vendor/mbedtls per https://issues.couchbase.com/browse/CBD-2828
for i in .repo .git fleece gradle Docs doc test tests docs googletest third_party _obsolete mbedtls VisualStudio dotzlib MYUtilities; do
   find . -type d -name $i | xargs rm -rf
done
