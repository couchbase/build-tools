#!/bin/bash -ex

pushd mcp-server-couchbase

# The docs site ships in the sdist; its npm lockfile (docusaurus etc.) would
# pollute the BOM with docs-only dependencies.
rm -rf website

# Tests and dev tooling are not part of the shipped package.
rm -rf tests scripts

# pyproject.toml + uv.lock are the UV detector's inputs (get_source.sh
# already stripped the dev extra from both), so keep them. The other
# pyproject-triggered detectors don't fire: POETRY needs [tool.poetry] and
# SETUPTOOLS needs a setuptools build backend (this project uses hatchling).
#
# Make sure no requirements*.txt sneaks into the scan: the PIP detectors
# treat every line of one as a *direct* dependency, which is exactly the
# all-direct BOM bug this setup exists to avoid.
rm -f requirements*.txt

popd
