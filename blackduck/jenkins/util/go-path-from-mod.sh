#!/usr/bin/env bash

SCRIPT_DIR=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

# Source this script in a blackduck get_source.sh or get_additional_source.sh
# to install the version of go specified in ./go.mod - failing over to the
# latest supported if the one in go.mod couldn't be installed

if [ -f "go.mod" ]; then
    GOVER=$(grep "^go " go.mod | cut -d " " -f2)
    mkdir -p "${WORKSPACE}/extra"

    if cbdep install -d "${WORKSPACE}/extra" golang ${GOVER}; then
        printf "${WORKSPACE}/extra/go${GOVER}/bin"
    else
        "${SCRIPT_DIR}/go-path-from-latest.sh"
    fi
fi
