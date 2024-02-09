#!/bin/bash -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export PATH="$(${SCRIPT_DIR}/../jenkins/util/get-go-path.sh):$PATH"
