#!/bin/bash -x

usage() {
    echo "No package info is provided."
    echo "Usage: $0 <file path>"
    exit 1
}

notarize_pkg() {
    echo "-------Notarizing for ${PKG}-------"
    XML_OUTPUT=$(xcrun notarytool submit "${PKG}" \
        --keychain-profile "COUCHBASE_AC_PASSWORD" \
        --keychain "~/Library/Keychains/login.keychain-db" \
        --output-format plist
    )
    if [ $? != 0 ]; then
        ERROR_MSG=$(
            echo "${XML_OUTPUT}" | \
            xmllint --xpath '//dict/key[text() = "message"]/following-sibling::string[1]/text()' -
        )
        echo "Error running notarize command!"
        echo "${ERROR_MSG}"
        exit 1
    fi

    REQUEST_ID=$(
        echo "${XML_OUTPUT}" | \
            xmllint --xpath '//dict[key/text() = "id"]/string[1]/text()' -
    )
    echo "Notarization request, ${REQUEST_ID} has been uploaded."

    while true; do
        XML_OUTPUT=$(
            xcrun notarytool info "${REQUEST_ID}" \
                --keychain-profile "COUCHBASE_AC_PASSWORD" \
                --keychain "~/Library/Keychains/login.keychain-db" \
                --output-format plist 2>&1
        )
        if [ $? != 0 ]; then
            echo "Error checking on status for ${REQUEST_ID} - will ignore and keep trying"
            return 1
        fi
        STATUS=$(echo "${XML_OUTPUT}" | \
            xmllint --xpath '//dict/key[text() = "status"]/following-sibling::string[1]/text()' -
        )
        case ${STATUS} in
            Accepted)
                echo "Request ${REQUEST_ID} succeeded!"
                ### https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow
                ### Only need to staple dmg or pkg.
                if [[ ${PKG} == *.dmg || ${PKG} == *.pkg ]]; then
                    echo =========================================
                    echo "Stapling notarization ticket to ${PKG}"
                    echo =========================================
                    xcrun stapler staple "${PKG}"
                fi
                #In case the package has "unnotarized" in its name, remove it.
                PKG_NOTARIZED="${PKG//-unnotarized//}"
                mv "${PKG}" "${PKG_NOTARIZED}"
                exit
                ;;
            "In Progress")
                echo "Request ${REQUEST_ID} still in progress..."
                ;;
            Invalid|Rejected)
                echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                echo "Request ${REQUEST_ID} failed notarization!"
                echo "${XML_OUTPUT}"
                echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                exit 1
                ;;
            *)
                echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                echo "Request ${REQUEST_ID} had surprising status ${STATUS}, quitting..."
                echo "${XML_OUTPUT}"
                echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                exit 1
            ;;
        esac
        echo "Wait for a minute before checking it again..."
        sleep 60
    done
}

##Main

if [[ $# -eq 0 ]] ; then
    usage
fi
PKG=${1}
notarize_pkg
