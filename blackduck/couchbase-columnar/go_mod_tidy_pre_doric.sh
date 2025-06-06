#!/bin/bash -ex

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# "go mod tidy" handling for pre-Doric releases. Expects to be run in
# the src/ directory.

# If we find any go.mod files with zero "require" statements, they're probably one
# of the stub go.mod files we introduced to make other Go projects happy. Black Duck
# still wants to run "go mod why" on them, which means they need a full set of
# replace directives.
for stubmod in $(find . -name go.mod \! -execdir grep --quiet require '{}' \; -print); do
    cat ${SCRIPT_DIR}/go-mod-replace.txt >> ${stubmod}
done

# Need to fake the generated go files in indexing, eventing, and eventing-ee
for dir in secondary/protobuf; do
    mkdir -p goproj/src/github.com/couchbase/indexing/${dir}
    touch goproj/src/github.com/couchbase/indexing/${dir}/foo.go
done
for dir in auditevent flatbuf/cfg flatbuf/cfgv2 flatbuf/header flatbuf/header_v2 flatbuf/payload flatbuf/response parser version; do
    mkdir -p goproj/src/github.com/couchbase/eventing/gen/${dir}
    touch goproj/src/github.com/couchbase/eventing/gen/${dir}/foo.go
done
for dir in gen/nftp/client evaluator/impl/gen/parser evaluator/impl/v8wrapper/process_manager/gen/flatbuf/payload; do
    mkdir -p goproj/src/github.com/couchbase/eventing-ee/${dir}
    touch goproj/src/github.com/couchbase/eventing-ee/${dir}/foo.go
done

# Delete a bunch of unwanted cruft in flatbuffers
if [ -d godeps/src/github.com/google/flatbuffers ]; then
    pushd godeps/src/github.com/google/flatbuffers
    rm -rf samples examples grpc/examples dart rust tests Package.swift pubspec.yaml
    popd
fi

# Call "go mod tidy" in each directory with a go.mod file until there
# are no further changes in the repo sync
diff_checksum=$(repo diff -u | sha256sum)
while true; do
    for gomod in $(find . -name go.mod); do
        pushd $(dirname ${gomod})
        grep --quiet require go.mod || {
            popd
            continue
        }
        go mod tidy
        popd
    done
    curr_checksum=$(repo diff -u | sha256sum)
    if [ "${diff_checksum}" = "${curr_checksum}" ]; then
        break
    fi
    echo
    echo "Repo was changed - re-running go mod tidy"
    echo
    diff_checksum="${curr_checksum}"
done
