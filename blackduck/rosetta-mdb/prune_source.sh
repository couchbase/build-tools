#!/bin/bash -ex

# Only rosetta-mdb and rosetta-mdb-crs should be scanned; remove anything
# else at the root of the source directory.
find . -mindepth 1 -maxdepth 1 ! -name rosetta-mdb ! -name rosetta-mdb-crs -exec rm -rf {} +

rm -rf \
    rosetta-mdb/target \
    rosetta-mdb-crs/target \
    rosetta-mdb/crates/*/tests
