#!/bin/bash -x

usage() {
    cat << EOF
Notarize a Couchbase Server build
Usage: $0 -r RELEASE -v VERSION -b BLD_NUM -a ARCH
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

#unlock keychain
unlock_keychain

# default to notarize both community and enterprise
EDITION="community enterprise"

while getopts 'r:v:e:b:a:' options; do
    case "$options" in
        r) RELEASE=${OPTARG};;
        v) VERSION=${OPTARG};;
        e) EDITION=${OPTARG};;
        b) BLD_NUM=${OPTARG};;
        a) ARCH=${OPTARG};;
        \?) usage;;
    esac
done

if [ -z "${RELEASE}" -o -z "${VERSION}" -o -z "${BLD_NUM}" -o -z "${ARCH}" ]; then
    usage
fi

DMG_URL_DIR=http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}

declare -a DMGS
declare -a UNNOTARIZED
for edition in ${EDITION}; do
    DMGS+=(couchbase-server-${edition}_${VERSION}-${BLD_NUM}-macos_${ARCH}-unnotarized.dmg)
done

# Check if DMGS are notarized
for file in ${DMGS[*]}; do
    notarized_file=`echo ${file} |sed "s/-unnotarized.dmg/.dmg/"`
    if curl --head --silent --fail ${DMG_URL_DIR}/${notarized_file} 2> /dev/null;
    then
        echo "${DMG_URL_DIR}/${notarized_file} already exist."
        echo "No need to notarize this again."
    else
        if curl --head --silent --fail ${DMG_URL_DIR}/${file} 2> /dev/null;
        then
            echo "Downloading ${DMG_URL_DIR}/${file}..."
            curl -O ${DMG_URL_DIR}/${file}
            UNNOTARIZED+=( ${file} )
        else
            echo "${DMG_URL_DIR}/${file} does not exist. Aborting..."
            exit 1
        fi
    fi
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
                notarized_file_name=`echo ${UNNOTARIZED[$i]} |sed "s/-unnotarized.dmg/.dmg/"`
                mv ${UNNOTARIZED[$i]} ${notarized_file_name}
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
