#!/bin/bash -ex

# The corresponding Poetry.lock isn't checked in, so the scan fails. This
# file only (currently?) references build-time dependencies anyway, so just
# delete it.
rm -f couchbase-python-client/pyproject.toml
