#!/bin/bash -e

# See if 'repo' knows about GOVERSION
cd "${WORKSPACE}/src"
repogover=$(repo forall build -c 'echo $REPO__GOVERSION')
GOVER=${repogover:-1.17.1}
cbdep install -d "${WORKSPACE}/extra/install" golang ${GOVER} >& /dev/null
echo "PATH=${WORKSPACE}/extra/install/go${GOVER}/bin:${PATH}"
