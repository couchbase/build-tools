#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

# Extract Golang version to use from manifest
GOANNOTATION=$(xmllint \
    --xpath 'string(//project[@name="build"]/annotation[@name="GOVERSION"]/@value)' \
    manifest.xml)
GOVERSION=${GOANNOTATION:-1.13.3}

# Create temp directory in WORKSPACE to install golang
GODIR=$(mktemp -d -q --tmpdir=$(pwd) golangXXXXX)
cbdep install -d ${GODIR} golang ${GOVERSION}
export PATH=${GODIR}/go${GOVERSION}/bin:${PATH}

cd ${PRODUCT}
make dist

if [ "${PRODUCT}" != "couchbase-operator" ]; then
    exit 0
fi

# Special case code for couchbase-operator: Notarize the command-line programs
set +x
for file in dist/*.zip
do
    case "$file" in
        *"operator"*"macos"*".zip")
        echo "Signing and notarizing $file"
        platform=$(echo $file | sed -e 's/.*\(kubernetes\|openshift\).*/\1/g')
        bundle="com.couchbase.autonomous-operator-${platform}-${VERSION}-${BLD_NUM}"
        curl -Lsf -o "${file}" \
                -X POST \
                -F "notarize=true" \
                -F "binary_locations=bin" \
                -F "bundle=${bundle}" \
                -F "content=@${file}" \
                -F "token=$(cat ~/.ssh/notarizer_token)" \
                http://172.23.113.4:7000/zip/${file//dist\//}
        ;;
    esac
done
