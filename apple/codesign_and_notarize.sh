#!/bin/zsh -e

# Script to codesign and notarize the expected set of artifacts for a
# given product build.
#
# This script assumes that the unsigned and un-notarized artifacts are
# uploaded to latestbuilds in one of two locations, relative to the
# build's normal output directory:
#
#  - <BLD_DIR>/unfinished/<ARTIFACT_NAME>.<EXT>
#  - <BLD_DIR>/<ARTIFACT_NAME>_unsigned.<EXT>
#
# For couchbase-server .dmg files, the unsigned/un-notarized artifacts
# are .zip files in one of two locations:
#
#  - <BLD_DIR>/unfinished/<ARTIFACT_NAME>.zip
#  - <BLD_DIR>/<ARTIFACT_NAME>-unsigned.zip
#
# If any expected unsigned/un-notarized artifact does not exist in one
# of those two places, the script will quietly exit without doing
# anything. This is to allow all expected artifacts to be notarized in
# parallel once they are all available.
#
# This script further assumes that the signed and notarized artifacts
# are uploaded to latestbuilds in the build's normal output directory
# with the final artifact filename, and that nothing will upload
# unsigned or un-notarized artifacts to that location. As such, if any
# files exist in those locations, this script will quietly ignore the
# corresponding unsigned/un-notarized artifact. This is to prevent
# wasting time uploading an already-notarized artifact to Apple.
#
# If the script does any signing/notarizing, all the final artifacts
# (and nothing else) will be in a subdirectory named "dist".

SCRIPT_DIR=${0:A:h}
. "${SCRIPT_DIR}/../utilities/shell-utils.sh"

function usage
{
    echo "\nUsage: $0 -p <Product> -r <Release> -v <Version> -b <Build>\n"
    echo "  -p Product:  couchbase-server|sync_gateway|couchbase-lite-c|couchbase-operator"
    echo "  -r Release: eg. trinity, 3.1.0"
    echo "  -v Version: eg. 7.2.0, 3.1.0"
    echo "  -b Build Number: eg. 123"
}

# Check if final artifact name is for a Server .dmg
function is-server-dmg
{
    [[ $1 = couchbase-server-*.dmg ]]
}

while getopts b:p:r:v: opt
do
    case ${opt} in
    b) BLD_NUM=${OPTARG}
        ;;
    p) PRODUCT=${OPTARG}
        ;;
    r) RELEASE=${OPTARG}
        ;;
    v) VERSION=${OPTARG}
        ;;
    *) usage
       ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${VERSION} || -z ${RELEASE} || -z ${BLD_NUM} ]]; then
    usage
    exit 1
fi

BLD_DIR=https://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}

# Set up array of expected artifact final filenames.
expected=()
do_notarize=true
case ${PRODUCT} in
sync_gateway)
    expected+=(couchbase-sync-gateway-enterprise_${VERSION}-${BLD_NUM}_x86_64.zip)
    expected+=(couchbase-sync-gateway-enterprise_${VERSION}-${BLD_NUM}_arm64.zip)
    expected+=(couchbase-sync-gateway-community_${VERSION}-${BLD_NUM}_x86_64.zip)
    expected+=(couchbase-sync-gateway-community_${VERSION}-${BLD_NUM}_arm64.zip)
    ;;
couchbase-lite-c)
    # This product contains only libraries etc., which cannot be notarized
    do_notarize=false
    expected+=(${PRODUCT}-enterprise-${VERSION}-${BLD_NUM}-macos.zip)
    expected+=(${PRODUCT}-enterprise-${VERSION}-${BLD_NUM}-macos-symbols.zip)
    expected+=(${PRODUCT}-community-${VERSION}-${BLD_NUM}-macos.zip)
    expected+=(${PRODUCT}-community-${VERSION}-${BLD_NUM}-macos-symbols.zip)
    ;;
couchbase-server)
    expected+=(${PRODUCT}-enterprise_${VERSION}-${BLD_NUM}-macos_x86_64.dmg)
    expected+=(${PRODUCT}-enterprise_${VERSION}-${BLD_NUM}-macos_arm64.dmg)
    expected+=(${PRODUCT}-community_${VERSION}-${BLD_NUM}-macos_x86_64.dmg)
    expected+=(${PRODUCT}-community_${VERSION}-${BLD_NUM}-macos_arm64.dmg)
    ;;
couchbase-operator)
    expected+=(couchbase-autonomous-operator_${VERSION}-${BLD_NUM}-kubernetes-macos-amd64.zip)
    expected+=(couchbase-autonomous-operator_${VERSION}-${BLD_NUM}-kubernetes-macos-arm64.zip)
    expected+=(couchbase-autonomous-operator_${VERSION}-${BLD_NUM}-openshift-macos-amd64.zip)
    expected+=(couchbase-autonomous-operator_${VERSION}-${BLD_NUM}-openshift-macos-arm64.zip)
    ;;
*)
    header "Unsupported product ${PRODUCT}, nothing to do..."
    exit 0
    ;;
esac

# Drop any files from the artifacts list that already exist in their
# final location on latestbuilds, as these are presumed to be signed and
# notarized already
needed=()
for pkg in $expected; do
    if curl --head --silent --fail ${BLD_DIR}/${pkg} &> /dev/null;
    then
        status "${BLD_DIR}/${pkg} already exists."
        status "No need to sign/notarize this again."
    else
        needed+=(${pkg})
    fi
done

if [ ${#needed} = 0 ]; then
    header "All expected final artifacts already exist - nothing to do!"
    exit 0
fi

# Ok, some final files don't exist yet - see if all the ones we need
# exist as unsigned/un-notarized files in either expected location,
# remembering those locations as we find them
typeset -A urls=()
for pkg in $needed; do

    # The unsigned version of a Server .dmg file is actually a .zip,
    # in slightly different potential locations
    candidate_urls=()
    if is-server-dmg ${pkg}; then
        candidate_urls+=(${BLD_DIR}/${pkg:r}-unsigned.zip)
        candidate_urls+=(${BLD_DIR}/unfinished/${pkg:r}.zip)
    else
        candidate_urls+=(${BLD_DIR}/unfinished/${pkg})
        candidate_urls+=(${BLD_DIR}/${pkg:r}_unsigned.${pkg:e})
    fi

    for candidate_url in $candidate_urls; do
        if curl --head --silent --fail $candidate_url &> /dev/null;
        then
            urls[${pkg}]=${candidate_url}
            # For Server Enterprise, add tools package(s) to the list
            # After 7.6.3, tools package is split into admin-tools and dev-tools.
            # If tools zip doesn't exist, we assume 7.6.4; add admin-tools|dev-tools instead.
            if [[ ${pkg} = "couchbase-server-enterprise"* ]]; then
                tools_pkg=${${pkg:r}//enterprise/tools}.zip
                if curl --head --silent --fail ${BLD_DIR}/${tools_pkg} &> /dev/null;
                then
                    urls[${tools_pkg}]=${BLD_DIR}/${tools_pkg}
                else
                    admin_tools_pkg=${${pkg:r}//enterprise_/admin-tools-}.zip
                    dev_tools_pkg=${${pkg:r}//enterprise_/dev-tools-}.zip
                    urls[${admin_tools_pkg}]=${BLD_DIR}/${admin_tools_pkg}
                    urls[${dev_tools_pkg}]=${BLD_DIR}/${dev_tools_pkg}
                fi
            fi
            break
        fi
    done

    if [ -z "$urls[${pkg}]" ]; then
        header "Unsigned ${pkg} doesn't exist yet; not signing anything!"
        exit 0
    fi
done
# Ok, we have stuff to do! Download all unsigned files to their *final*
# filenames in a new 'dist' directory. Yes, this means we'll download a
# Server unsigned .zip file with a .dmg filename; we'll fix that up next.
rm -rf dist
mkdir dist
cd dist
for pkg url in ${(kv)urls}; do
    status "Downloading ${url}..."
    curl --silent --fail -o ${pkg} ${url}
done

# Codesign each file.
for pkg in ${(k)urls}; do
    header "Codesigning ${pkg}..."
    if is-server-dmg ${pkg}; then
        # Server ".dmg" files are actually the unsigned .zip; fix that
        # up, and delete the .zip after the signed .dmg is created.
        zippkg=${pkg:r}.zip
        mv ${pkg} ${zippkg}
        "${SCRIPT_DIR}/codesign/codesignApple_server.sh" ${zippkg} ${pkg}
        rm ${zippkg}
    else
        "${SCRIPT_DIR}/codesign/codesignApple_simple.sh" ${pkg}
    fi
done

# Now notarize the whole bunch.
if ${do_notarize}; then
    header "Notarizing all files..."
    "${SCRIPT_DIR}/notarization/notarize_simple.sh" *
else
    header "Skipping notarization for product ${PRODUCT}..."
fi

echo
echo
echo "All done!"
echo
