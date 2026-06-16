#!/bin/bash -ex
pushd agentmemory-sdk
# Test/dev tooling, examples and docs are not part of the shipped package.
rm -rf tests examples docs
popd
