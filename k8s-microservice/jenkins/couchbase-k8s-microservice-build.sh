#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

GOVERSION=$(repo forall build -c 'echo ${REPO__GOVERSION:-1.13.3}')
GODIR=${HOME}/golang
mkdir -p ${GODIR}
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
        platform=$(echo $file | sed -e "s/.*operator-\([^_]*\).*/\1/g")
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
