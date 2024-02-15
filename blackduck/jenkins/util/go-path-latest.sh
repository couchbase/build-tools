#!/bin/bash

if [ ! -f "${WORKSPACE}/extra/cbdep/cbdep" ]; then
    mkdir -p "${WORKSPACE}/extra/cbdep"
    curl -fLo "${WORKSPACE}/extra/cbdep/cbdep" https://downloads.build.couchbase.com/cbdep/cbdep.linux
    chmod a+x "${WORKSPACE}/extra/cbdep/cbdep"
fi

LATEST_MAJOR_MINOR=$(curl -s "https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/SUPPORTED_NEWER.txt")
GOVER=$(curl -s "https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/${LATEST_MAJOR_MINOR}.txt")
"${WORKSPACE}/extra/cbdep/cbdep" install -d "${WORKSPACE}/extra" golang ${GOVER} >&/dev/null
printf "${WORKSPACE}/extra/go${GOVER}/bin"
