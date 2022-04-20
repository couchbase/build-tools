#!/bin/bash -ex

# Test framework, don't scan (and it causes Black Duck to choke as mvn
# can't even run on this pom.xml without manually adding libraries)
rm -rf couchbase-jvm-clients/java-fit-performer
