#!/bin/bash -ex

pushd agent-core

# Tests, build tooling, and docs are not part of the shipped package.
rm -rf tests scripts docs

# Not shipped code -- the release binary is built via PyInstaller
# (make build/zip), not the Dockerfile.
rm -f Dockerfile .dockerignore

# Make sure no requirements*.txt sneaks into the scan: the PIP detectors
# treat every line of one as a *direct* dependency, duplicating (and
# flattening) what the UV detector (pyproject.toml + uv.lock) already
# reports correctly. detect.detector.search.depth is 9, so check every
# level, not just the root.
find . -iname "requirements*.txt" -delete

popd
