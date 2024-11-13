#!/bin/bash -ex

declare -A CARTHAGE_PKGS
case ${PRODUCT} in
    "couchbase-lite-vector-search")
        CARTHAGE_PKGS["CouchbaseLiteVectorSearch.json"]="${PRODUCT}_xcframework_${VERSION}.zip"
        ;;
    "couchbase-lite-ios")
        CARTHAGE_PKGS["CouchbaseLite-Enterprise.json"]="couchbase-lite-carthage-enterprise-${VERSION}.zip"
        if [[ ${COMMUNITY} == "yes" ]]; then
            CARTHAGE_PKGS["CouchbaseLite-Community.json"]="couchbase-lite-carthage-community-${VERSION}.zip"
        fi
        ;;
    "*")
        echo "${PRODUCT} is not supported!"
        exit 1
        ;;
esac

for fl in ${!CARTHAGE_PKGS[@]}; do
    curl --fail -LO http://packages.couchbase.com/releases/${PRODUCT}/carthage/${fl} || exit 1
    python3 ${WORKSPACE}/build-tools/release/carthage/carthage_json.py --product ${PRODUCT} \
        --version ${VERSION} \
        --file ${fl} \
        --carthage ${CARTHAGE_PKGS[${fl}]} || exit 1
done

if [[ ${DRYRUN} == 'false' ]]; then
    for fl in ${!CARTHAGE_PKGS[@]}; do
        aws s3 cp $fl s3://packages.couchbase.com/releases/${PRODUCT}/carthage/${fl} --acl public-read || exit 1
        echo "${fl}:"
        cat ${fl}
        echo ""
    done
else
    echo "Dryrun mode is on.  Print Json content instead of publishing to s3"
    for fl in ${!CARTHAGE_PKGS[@]}; do
        echo "${fl}:"
        cat ${fl}
        echo ""
    done
fi
