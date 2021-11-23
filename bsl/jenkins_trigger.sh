#!/bin/bash -e

NODE_VERSION=17.1.0

[ ! -f "./cbdep" ] || ! ./cbdep --version &>/dev/null \
    && echo "Downloading cbdep" \
    && curl http://downloads.build.couchbase.com/cbdep/cbdep.linux -o ./cbdep && chmod 755 ./cbdep

[ ! -f "./nodejs-${NODE_VERSION}/bin/node" ] \
    && echo "Installing node" \
    && ./cbdep install -d . nodejs ${NODE_VERSION}

export PATH=$(pwd)/nodejs-${NODE_VERSION}/bin:$PATH

./update-bsl-for-manifest ${DRY_RUN_ARG} ${FORCE_ARG} \
    -u "${MANIFEST_REPO}" \
    -m "${MANIFEST}"
