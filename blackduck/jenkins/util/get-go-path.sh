#!/bin/bash -e

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))
source ${script_dir}/../../../utilities/shell-utils.sh

chk_set PRODUCT

# Read GOVERSION from manifest
GOVERSION=$(gover_from_manifest)

# Historic only: If GOVERSION isn't set, assume 1.18.5
if [ -z "${GOVERSION}" ]; then
    GOVERSION=1.18.5
fi

# Cons up a black-duck-manifest for Golang
cat <<EOF > "${WORKSPACE}/src/${PRODUCT}-black-duck-manifest.yaml"
components:
  go programming language:
    bd-id: 6d055c2b-f7d7-45ab-a6b3-021617efd61b
    versions: [ ${GOVERSION} ]
EOF

# Install golang and add to PATH
cbdep install -d "${WORKSPACE}/extra/install" golang ${GOVERSION} >& /dev/null

echo "${WORKSPACE}/extra/install/go${GOVERSION}/bin"
