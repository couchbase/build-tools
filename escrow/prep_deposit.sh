#!/bin/bash -e

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

cd ${SCRIPTPATH}
source ./escrow_config
cd ./output/${PRODUCT}-${VERSION}/src
rm -rf *.deb \
       *.tar.gz \
       .repo \
       server_build
cd ../..
tar -czvf ${PRODUCT}-${VERSION}.tar.gz ${PRODUCT}-${VERSION}
