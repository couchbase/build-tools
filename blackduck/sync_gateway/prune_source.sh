#!/bin/bash -ex

#clean up unnecessary source directories

# Remove un-needed ns_server got pull in for to use <!-- gozip tools --> purpose
rm -rf godeps/src/github.com/couchbase/ns_server
# Remove jQuery from scan CBD-2977
rm -rf godeps/src/github.com/couchbase/cbgt/rest/static/lib/jquery

#Remove beorn7 and golang_protobuf_extensions from scan CBD-3616
rm -rf godeps/src/github.com/beorn7
rm -rf godeps/src/github.com/matttproud/golang_protobuf_extensions

# nothing in the build repo should affect third-party reports
rm -rf cbbuild
