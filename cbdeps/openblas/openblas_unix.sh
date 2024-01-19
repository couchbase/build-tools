#!/bin/bash

PROFILE=$4

scriptdir="$(realpath $( dirname -- "$BASH_SOURCE"; ))";
if [ "$PROFILE" == "lite" ]; then
    $scriptdir/openblas_lite_unix.sh "$@"
else
    $scriptdir/openblas_server_unix.sh "$@"
fi
