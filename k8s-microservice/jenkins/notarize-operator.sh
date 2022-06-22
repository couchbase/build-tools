#!/bin/bash -ex

if [ "${PRODUCT}" != "couchbase-operator" ]; then
    exit 0
fi

cd "${PRODUCT}"

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
