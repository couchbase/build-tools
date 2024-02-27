#!/bin/bash

usage() {
    cat << EOF
Notarize any number of files in-place, in parallel
Usage: $0 <file> [ <file> ... ]
EOF
    exit 1
}

function unlock_keychain {
    #unlock keychain
    #${KEYCHAIN_PASSWORD} is injected as an env password in jenkins job
    echo "------- Unlocking keychain -----------"
    security unlock-keychain -p ${KEYCHAIN_PASSWORD} ${HOME}/Library/Keychains/login.keychain-db
}

check_notarization_status() {
    request=$1

    XML_OUTPUT=$(
        xcrun notarytool info ${request} \
        --keychain-profile "COUCHBASE_AC_PASSWORD" \
        --keychain "~/Library/Keychains/login.keychain-db" \
        --output-format plist
        2>&1
    )
    if [ $? != 0 ]; then
        echo "Error checking on status for ${request} - will ignore and keep trying"
        return 1
    fi

    if [ -n "$XML_OUTPUT" ]; then
        STATUS=$(
            echo "$XML_OUTPUT" | \
            xmllint --xpath '//dict/key[text() = "status"]/following-sibling::string[1]/text()' -
        )
    else
        echo "XML_OUTPUT is empty = - will ignore and keep trying"
        return 1
    fi
    case ${STATUS} in
        Accepted)
            echo "Request ${request} succeeded!"
            return 0
            ;;
        "In Progress")
            echo "Request ${request} still in progress..."
            return 1
            ;;
        Invalid|Rejected)
            echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            echo "Request ${request} failed notarization!"
            echo "$XML_OUTPUT"
            echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            return 2
            ;;
        *)
            echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            echo "Request ${request} had surprising status ${STATUS}, quitting..."
            echo "$XML_OUTPUT"
            echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            return 2
            ;;
    esac
}

##Main

unlock_keychain

if [[ $# -eq 0 ]] ; then
    usage
fi

# Initialize UNNOTARIZED array of files
declare -a UNNOTARIZED
for pkg in "$@"; do
    UNNOTARIZED+=(${pkg})
done

# Start notarization process
declare -a REQUESTS
for file in ${UNNOTARIZED[*]}; do
    echo "Starting notarization for ${file} (takes a few moments)"
    XML_OUTPUT=$(
        xcrun notarytool submit ${file} \
        --keychain-profile "COUCHBASE_AC_PASSWORD" \
        --keychain "~/Library/Keychains/login.keychain-db" \
        --output-format plist
    )
    if [ $? != 0 ]; then
        ERROR_MSG=$(
            echo "$XML_OUTPUT" | \
            xmllint --xpath '//dict/key[text() = "message"]/following-sibling::string[1]/text()' -
        )
        echo "Error running notarize command!"
        echo "$ERROR_MSG"
        exit 1
    else
        REQUEST_ID=$(
           echo "$XML_OUTPUT" | \
           xmllint --xpath '//dict[key/text() = "id"]/string[1]/text()' -
        )
        echo "Notarization started - request ID is ${REQUEST_ID}"
        REQUESTS+=( ${REQUEST_ID} )
        echo
    fi
done

# Wait for completion of all requests
while true; do
    for i in ${!REQUESTS[@]}; do
        check_notarization_status ${REQUESTS[$i]}
        case $? in
            0)
                # Success! Staple the ticket to the result
                echo =========================================
                echo "Stapling notarization ticket to ${UNNOTARIZED[$i]}"
                echo =========================================
                xcrun stapler staple ${UNNOTARIZED[$i]}
                # Don't check this one anymore
                unset REQUESTS[$i]
                echo
                ;;
            1)
                # Need to keep checking this one
                ;;
            2)
                # Don't check and remember there was a failure
                unset REQUESTS[$i]
                export JOB_FAILED=1
                echo
                ;;
        esac
    done
    if [ ${#REQUESTS[@]} = 0 ]; then
        break
    fi
    echo "Waiting a minute to check again..."
    sleep 60
done

echo
echo =========================================
echo "All done!"
echo =========================================
if [ ! -z "${JOB_FAILED}" ]; then
    echo "Some jobs failed..."
    exit 1
fi
