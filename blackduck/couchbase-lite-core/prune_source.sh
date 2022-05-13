#!/bin/bash -ex

pwd

# remove LiteCore-iOS and libstemmer_c per CBD-3616
rm -rf couchbase-lite-core/Xcode/LiteCore-iOS/LiteCore-iOS

# A few directories that we want to prune in older cbl-core versions
# that don't have a black-duck-manifest that names specific paths.
manifest=$(find "${WORKSPACE}" -maxdepth 9 -name couchbase-lite-core-black-duck-manifest.yaml)
if [ "${#manifest[@]}" = "0" ]; then
    additional_deps="libstemmer_c"
fi

# cleanup unwanted stuff - test files, build scripts, etc.
# also remove first-party code such as fleece.
for i in fleece Docs doc test googletest cbbuild tlm ${additional_deps}; do
     find . -type d -name $i | xargs rm -rf
done
