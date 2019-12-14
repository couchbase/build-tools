#!/bin/bash -ex

#clean up unnecessary source directories

# Remove un-needed ns_server got pull in for to use <!-- gozip tools --> purpose
rm -rf godeps/src/github.com/couchbase/ns_server
# Remove jQuery from scan CBD-2977
rm -rf godeps/src/github.com/couchbase/cbgt/rest/static/lib/jquery

