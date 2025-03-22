#!/bin/bash -ex
#
# REMEMBER TO ALWAYS PRESERVE SYMLINKS WHEN ZIP and UNZIP
#
# Verification steps after codesign
# 1. spctl -avvvv pkg_name.app
#    Results "accepted" and Couchbase ID must be present
# 2. codesign -dvvvv pkg_name.app
#    Sealed resource must be version 2
# 3. Best to upload to another website (latestbuilds), download from there and rerun step #1 and #2
#
#

function usage {
    echo "Incorrect parameters..."
    echo -e "\nUsage:  ${0} <couchbase-server.zip> <couchbase-server.dmg>\n\n"
    exit 1
}

function unlock_keychain {
    #unlock keychain
    #${KEYCHAIN_PASSWORD} is injected as an env password in jenkins job
    echo "------- Unlocking keychain -----------"
    security unlock-keychain -p ${KEYCHAIN_PASSWORD} ${HOME}/Library/Keychains/login.keychain-db
}

##Main

if [[ "$#" < 2 ]] ; then usage ; fi

ZIP_FILENAME=${1}
DMG_FILENAME=${2}
if [[ ! "${DMG_FILENAME}" =~ ^/ ]]; then
    DMG_FILENAME=$(pwd)/${DMG_FILENAME}
fi

# enable nocasematch
shopt -s nocasematch

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )" #find out absolute path of the script

result="rejected"

tmpdir=$(mktemp -d $(pwd)/tmp.XXXXXXXX)
cleanup() {
    rm -rf "${tmpdir}"
}
trap cleanup EXIT
unzip -qq ${ZIP_FILENAME} -d ${tmpdir}
pushd ${tmpdir}

TEMPLATE_DMG_GZ=couchbase-server-macos-template_x86_64.dmg.gz
APP_NAME=$(ls -d *.app)

#protoc-gen-go was generated w/ sdk older than 10.9, it will cause notarization failure.
#it can be removed since it doesn't need to be shipped.
#it is not packaged in CC anymore, but still exist in older builds
if [[ -f "${APP_NAME}/Contents/Resources/couchbase-core/bin/protoc-gen-go" ]]; then
    rm -f "${APP_NAME}/Contents/Resources/couchbase-core/bin/protoc-gen-go"
fi

#move couchbase-server-macos-template_x86_64.dmg.gz out.  it will trigger notarization failure
mv "${APP_NAME}/Contents/Resources/${TEMPLATE_DMG_GZ}" .

#move .app and README into packaging directory
PKG_DIR=dmg-pkg
mkdir ${PKG_DIR}
mv *.app README.txt ${PKG_DIR}
pushd ${PKG_DIR}

echo ------- Unlocking keychain -----------
set +x
security unlock-keychain -p `cat ~/.ssh/security-password.txt` ${HOME}/Library/Keychains/login.keychain

###define codesigning flags and cert id
###use cb.entitlement.  mainly because of packaged adoptopenjdk
###they have to be resigned due to lack of runtime hardening.  missing necessary entitlements when using --preserve-metadata
###cb.entitlement consists of entitlements for basic java apps, which is similar to what is used by adoptopenjdk described in (https://medium.com/adoptopenjdk/bundling-adoptopenjdk-into-a-notarized-macos-application-f4d69404afc)
###In order to have consistent entitlements, it is best to use cb.entitlement for all codesiging.
sign_flags="--force --timestamp --options=runtime  --verbose --entitlements ${SCRIPTPATH}/cb.entitlement --preserve-metadata=identifier,requirements"
python_sign_flags="--force --timestamp --options=runtime  --verbose --entitlements ${SCRIPTPATH}/python.entitlement --preserve-metadata=identifier,requirements"
cert_name="Developer ID Application: Couchbase, Inc. (N2Q372V7W2)"

echo ------- Codesign options: $sign_flags -----------

echo ------- Sign binary files individually in Resources and Frameworks-------
set +e

find "${APP_NAME}/Contents/Resources" "${APP_NAME}/Contents/Frameworks" -type f \
| while IFS= read -r f
do
  ##binaries in jars have to be signed.
  ##It seems only jars in  META-INF are impacted so far.
  ##jars with .jnilib in other locations were not rejected
  if [[ "$f" = *".jar" ]]; then
    libs=`jar -tf "$f" | grep ".jnilib\|.dylib"`
    if [[ ! -z $libs ]]; then
      for l in ${libs}; do
        dir=$(echo ${l} |awk -F '/' '{print $1}')
        jar xf "$f" "$l"
        codesign $sign_flags --sign "$cert_name" "$l"
        jar uf "$f" "$l"
        rm -rf ${dir}
      done
    fi
  elif [[ `file --brief "$f"` =~ "Mach-O" ]]; then
    if [[ `echo $f | grep "couchbase-core/lib/python/interp"` ]]; then
        codesign $python_sign_flags --sign "$cert_name" "$f"
    else
        codesign $sign_flags --sign "$cert_name" "$f"
    fi
  fi
done
set -e

echo -------- Must sign Sparkle framework all versions ----------
codesign $sign_flags --sign "$cert_name" "${APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/A/Sparkle"
codesign $sign_flags --sign "$cert_name" "${APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/A"

codesign $sign_flags --sign "$cert_name" "${APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle"
codesign $sign_flags --sign "$cert_name" "${APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/Current"

echo --------- Sign Couchbase app --------------
codesign $sign_flags --sign "$cert_name" "${APP_NAME}"

popd

# Verify codesigned successfully
echo --------- Check signature of ${PKG_DIR}/*.app--------------
spctl -avvvv ${PKG_DIR}/*.app > tmp.txt 2>&1
cat tmp.txt
result=`grep "accepted" tmp.txt | awk '{ print $3 }'`
if [[ ${result} =~ "accepted" ]]; then
    # Ensure it's actually signed
    if [[ ! -z $(grep "no usable signature" tmp.txt) ]]; then
        exit 1
    fi
else
    exit 1
fi

# Create dmg package based on a template DMG we pull out of the app
echo "Creating DMG..."
WC_DIR=wc
WC_DMG=wc.dmg
rm -f ${DMG_FILENAME}
ln -f -s /Applications ${PKG_DIR}
#
rm -rf $WC_DMG
echo "Copying template..."
gzcat "${TEMPLATE_DMG_GZ}" > ${WC_DMG}
# pad 'du' size to ensure there is enough storage space
# enterprise complains w/o padding.
DMG_SIZE=$(du -sm ${PKG_DIR} |awk '{print($1 + 20)}')M
echo "Resizing DMG to ${DMG_SIZE}..."
echo "It may need to be resized again if ditto errors out with No space left on device".
hdiutil resize -size ${DMG_SIZE} ${WC_DMG}
#
echo "Mounting template to working image..."
mkdir -p ${WC_DIR}
#
hdiutil attach $WC_DMG -readwrite -nobrowse -mountpoint $WC_DIR
echo "Updating working image files..."
rm -rf $WC_DIR/*.app
ditto -rsrc "${PKG_DIR}/${APP_NAME}" "$WC_DIR/${APP_NAME}"
ditto -rsrc ${PKG_DIR}/README.txt $WC_DIR/README.txt
#
sleep 2
echo "Detaching image..."
hdiutil detach `pwd`/$WC_DIR
sleep 2
rm -f "$MASTER_DMG"
echo "Converting working image to new master..."
hdiutil convert "$WC_DMG" -format UDZO -o "${DMG_FILENAME}"
rm -rf $WC_DIR
rm $WC_DMG
echo "Done with DMG."


echo "CB_PRODUCTION_BUILD is ${CB_PRODUCTION_BUILD}"
# force sign dmg pkg - only if CB_PRODUCTION_BUILD defined
if [[ ${CB_PRODUCTION_BUILD} == 'true' ]]; then
    echo --------- Sign ${DMG_FILENAME} --------------
    echo "Codesign with options: $sign_flags"
    result=`codesign $sign_flags --sign "Developer ID Application: Couchbase, Inc. (N2Q372V7W2)" ${DMG_FILENAME}`

    if [ ${result} > 0 ]; then
        echo "codesign returned with an error"
        exit 1
    fi
fi

popd
