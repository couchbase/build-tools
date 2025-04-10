#!/bin/bash

LATEST_MAJOR_MINOR=$(curl -s "https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/SUPPORTED_NEWER.txt")
GOVER=$(curl -s "https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/${LATEST_MAJOR_MINOR}.txt")
mkdir -p "${WORKSPACE}/extra"
cbdep install -d "${WORKSPACE}/extra" golang ${GOVER} >&/dev/null
printf "${WORKSPACE}/extra/go${GOVER}/bin"
