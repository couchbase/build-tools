#!/bin/zsh -e

# Script to codesign arbitrary files. Currently only supports .zip files
# each possibly containing executables or jars, but could be extended in
# future.
# The file is codesigned in-place.

SCRIPT_DIR=${0:A:h}

SIGN_FLAGS="--force --deep --timestamp --options=runtime  --verbose --entitlements ${SCRIPT_DIR}/cb.entitlement --preserve-metadata=identifier,requirements"
PYTHON_SIGN_FLAGS="--force --timestamp --options=runtime  --verbose --entitlements ${SCRIPT_DIR}/python.entitlement --preserve-metadata=identifier,requirements"
CERT_NAME="Developer ID Application: Couchbase, Inc. (N2Q372V7W2)"


usage() {
    cat << EOF
Codesign any number of files in-place
Usage: $0 <file> [ <file> ... ]
EOF
    exit 1
}

function unlock_keychain
{
    #unlock keychain
    #${KEYCHAIN_PASSWORD} is injected as an env password in jenkins job
    echo "------- Unlocking keychain -----------"
    security unlock-keychain -p ${KEYCHAIN_PASSWORD} ${HOME}/Library/Keychains/login.keychain-db
}

function codesign_pkg
{
    pkg=$1

    tmpdir=$(mktemp -d $(pwd)/tmp.XXXXXXXX)
    unzip -qq ${pkg} -d ${tmpdir}
    apps=(${tmpdir}/*.app(N))

    echo "------- Codesigning binaries within the package -------"
    find ${tmpdir} -type f | while IFS= read -r file
    do
        ##binaries in jars have to be signed.
        if [[ "${file}" = *".jar" ]]; then
            libs=$(jar -tf "${file}" | grep ".jnilib\|.dylib")
            if [[ ! -z ${libs} ]]; then
                for lib in ${libs}; do
                    dir=$(echo ${l} |awk -F '/' '{print $1}')
                    jar xf "${file}" "${lib}"
                    codesign ${(z)SIGN_FLAGS} --sign ${CERT_NAME} "${lib}"
                    jar uf "${file}" "${lib}"
                    rm -rf ${dir}
                done
                rm -rf META-INF
            fi
        elif [[ `file --brief "${file}"` =~ "Mach-O" ]]; then
            if [[ `echo ${file} | grep "sgcollect_info"` ]]; then
                codesign ${(z)PYTHON_SIGN_FLAGS} --sign "$CERT_NAME" "${file}"
            else
                codesign ${(z)SIGN_FLAGS} --sign ${CERT_NAME} "${file}"
            fi
        fi
    done

    pushd ${tmpdir}
    if [[ ${#apps[@]} -gt 0 ]]; then
        codesign ${(z)SIGN_FLAGS} --sign ${CERT_NAME} *.app
    fi
    zip --symlinks -r -X ../${pkg} *
    popd

    echo "------- Codesigning the package ${pkg} -------"
    codesign ${(z)SIGN_FLAGS} --sign ${CERT_NAME} ${pkg}

    rm -rf "${tmpdir}"
}

##Main

unlock_keychain

if [[ $# -eq 0 ]] ; then
    usage
fi

for pkg in "$@"; do
    codesign_pkg ${pkg}
done
