#!/bin/bash -e

# See if 'repo' knows about GOVERSION
cd "${WORKSPACE}/src"
repogover=$(repo forall build -c 'echo $REPO__GOVERSION')
GOVER=${repogover:-1.17.1}
mkdir -p "${WORKSPACE}/extra"
CBDEP="${WORKSPACE}/extra/cbdep"
curl --silent -Lf -o "${CBDEP}" http://downloads.build.couchbase.com/cbdep/cbdep.linux
chmod 755 "${CBDEP}"
"${CBDEP}" install -d "${WORKSPACE}/extra/install" golang ${GOVER} >& /dev/null
echo "PATH=${WORKSPACE}/extra/install/go${GOVER}/bin:${PATH}"
