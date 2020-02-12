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
  if [ "${dep}" = "libevent" ] || [ "${dep}" = "grpc" ]
  then
    echo "# Patch: TLM OpenSSL version -> 1.1.1d"
    sed -i'' -e "s/openssl VERSION 1.1.1b-cb3/openssl VERSION 1.1.1d-cb2/g" /home/couchbase/tlm/deps/manifest.cmake
    sed -i'' -e "s/openssl VERSION 1.1.1b-cb2/openssl VERSION 1.1.1d-cb2/g" /home/couchbase/tlm/deps/packages/libevent/CMakeLists.txt
    sed -i'' -e "s/openssl VERSION 1.1.1b-cb[3-4]/openssl VERSION 1.1.1d-cb2/g" /home/couchbase/tlm/deps/packages/grpc/CMakeLists.txt
    sed -i'' -e "s/OPENSSL_VERS=1.1.1b-cb[3-4]/OPENSSL_VERS=1.1.1d-cb2/g" /home/couchbase/tlm/deps/packages/grpc/CMakeLists.txt
  fi
}
