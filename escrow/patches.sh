# This file should contain any runtime patches that are applied during in-container-build

patch_curl() {
    # Fix for curl_unix.sh since globbing (as in CBDEP_OPENSSL_CACHE) doesn't work in [[ ]] conditionals.
  if [ "${dep}" = "curl" ]
  then
    echo "# Patch: Curl build conditional"
    sed -i'' -e "s/\[\[ \! -z \"\${LOCAL_BUILD}\" \&\& -f \${CBDEP_OPENSSL_CACHE} \]\]/\[ \! -z \"\${LOCAL_BUILD}\" -a -f \${CBDEP_OPENSSL_CACHE} \]/g" /home/couchbase/tlm/deps/packages/curl/build-tools/cbdeps/curl/curl_unix.sh
  fi
}

patch_v8  () {
  if [ "${dep}" = "v8" ]
  then
    # Repos used by v8 have changed location - see e.g. https://groups.google.com/forum/#!topic/gyp-developer/Z7j-ZMrpWR0
    # this patch sets up the DEPS and Makefile files to point at correct commits on the new targets.
    #
    # NOTE: v8 builds are currently failing, so is being pulled form packages.couchbase.com instead
    echo "# Patch: v8"
    # Deps
    sed -i'' -e "s/http\:\/\/gyp\.googlecode\.com\/svn\/trunk\@1831/https\:\/\/chromium\.googlesource\.com\/external\/gyp\@a3e2a5caf24a1e0a45401e09ad131210bf16b852/g" /home/couchbase/escrow/deps/v8/DEPS
    sed -i'' -e "s/http\:\/\/src\.chromium\.org\/svn\/trunk\/deps\/third_party\/cygwin\@66844/https\:\/\/chromium\.googlesource\.com\/chromium\/deps\/cygwin\@06a117a90c15174436bfa20ceebbfdf43b7eb820/g" /home/couchbase/escrow/deps/v8/DEPS
    sed -i'' -e "s/https\:\/\/src\.chromium\.org\/chrome\/trunk\/deps\/third_party\/icu46\@239289/https\:\/\/chromium\.googlesource\.com\/chromium\/third_party\/icu46\@58c586c0424f93b75bba83fe39c651b39d146da3/g" /home/couchbase/escrow/deps/v8/DEPS

    # Makefile
    sed -i'' -e "s/--revision 1831/--revision a3e2a5caf24a1e0a45401e09ad131210bf16b852/g" /home/couchbase/escrow/deps/v8/Makefile
    sed -i'' -e "s/--revision 239289/--revision 58c586c0424f93b75bba83fe39c651b39d146da3/g" /home/couchbase/escrow/deps/v8/Makefile
    sed -i'' -e "s/http\:\/\/gyp\.googlecode\.com\/svn\/trunk/https\:\/\/chromium\.googlesource\.com\/external\/gyp/g" /home/couchbase/escrow/deps/v8/Makefile
    sed -i'' -e "s/https\:\/\/src\.chromium\.org\/chrome\/trunk\/deps\/third_party\/icu46/https\:\/\/chromium\.googlesource\.com\/chromium\/third_party\/icu46/g" /home/couchbase/escrow/deps/v8/Makefile

    (
      cd /home/couchbase/escrow/deps/v8 && \
      git config --global user.name "Couchbase Build Team" && \
      git config --global user.email "buildteam@couchbase.com" && \
      git commit -am "Patch v8" || :
    )
  fi
}

patch_tlm_openssl() {
  # We have several dependencies which specify openssl as a dependency in their CMakeLists where the version is liable
  # to diverge from that in manifest.cmake over time. To account for this and ensure we are using the cached version of
  # openssl, we ensure the product's CMakeLists specify openssl deps match those present in manifest.cmake
  if [ "${dep}" = "erlang" ] || [ "${dep}" = "folly" ] || [ "${dep}" = "grpc" ] || [ "${dep}" = "libevent" ]
  then
    echo "# Patch: Ensure ${dep} OpenSSL versions match manifest.cmake"
    python3 - <<-EOF
import re
import urllib.request

# Read manifest.cmake at tip of master and create list containing only the declare_dep openssl lines
with open('${ROOT}/src/tlm/deps/manifest.cmake') as manifest:
  manifest_lines = manifest.readlines()
openssl_deps = [dep.strip() for dep in manifest_lines if re.match('[\s]*declare_dep[\s]*\([\s]*openssl', dep, flags=re.IGNORECASE)]

cmakelist_lines = open('deps/packages/${dep}/CMakeLists.txt', 'r').readlines()

# Find the first line where openssl is declare_dep'd to use as offset for insertion
for i, line in enumerate(cmakelist_lines):
  if re.match("[\s]*declare_dep[\s]*\([\s]*openssl", line, flags=re.IGNORECASE):
    ssl_offset = i+1
    break

# Create list of lines in cmakelist, minus declare_dep openssl sections
cmakelist_clean_lines = re.sub('declare_dep[\s]*\([\s]*openssl[^\)]*\)', '', ''.join(cmakelist_lines), flags=re.IGNORECASE).split('\n')

# Create new patched content and write to disk
cmakelist_patched = '\n'.join(cmakelist_clean_lines[0:ssl_offset] + openssl_deps + cmakelist_clean_lines[ssl_offset:])

f = open('deps/packages/${dep}/CMakeLists.txt', "w")
f.write(cmakelist_patched)
EOF

  if [ -f /home/couchbase/.cbdepscache/openssl-${PLATFORM}-x86_64-1.1.1d-cb2.tgz -a -f /home/couchbase/.cbdepscache/openssl-${PLATFORM}-x86_64-1.1.1d-cb2.md5 ]
  then
    echo "Creating legacy .tgz.md5"
    cp /home/couchbase/.cbdepscache/openssl-${PLATFORM}-x86_64-1.1.1d-cb2.md5 /home/couchbase/.cbdepscache/openssl-${PLATFORM}-x86_64-1.1.1d-cb2.tgz.md5
  fi
  fi
}
