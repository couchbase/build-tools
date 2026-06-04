#!/bin/bash -ex

pushd mcp-server-couchbase

# The docs site ships in the sdist; its npm lockfile (docusaurus etc.) would
# pollute the BOM with docs-only dependencies.
rm -rf website

# Tests and dev tooling are not part of the shipped package.
rm -rf tests scripts

# requirements.txt (generated from uv.lock in get_source.sh) is the sole
# input for the PIP detector; remove the project files so no other Python
# detector picks them up (uv.lock also pins the dev extras, which we don't
# want in the BOM).
rm -f pyproject.toml uv.lock

popd
