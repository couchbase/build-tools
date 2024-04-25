#!/bin/bash

# Copyright 2017-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.

set -ex

INSTALL_DIR=$1
ROOT_DIR=$2

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Build the main installation with je_ symbol prefix
"${SCRIPT_DIR}/scripts/build_jemalloc.sh" \
   "${ROOT_DIR}" \
   "--with-jemalloc-prefix=je_ --disable-cache-oblivious --disable-zone-allocator \
   --disable-initial-exec-tls --disable-cxx --with-lg-tcache-limit=15" \
   "${INSTALL_DIR}" \
   ""
