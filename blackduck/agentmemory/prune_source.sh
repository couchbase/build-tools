#!/bin/bash -ex
pushd agentmemory
# Test/dev tooling, examples and docs are not part of the shipped package.
rm -rf tests examples docs

rm -f requirements.in
popd
