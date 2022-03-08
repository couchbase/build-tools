#!/bin/bash -ex

NODE_VERSION=17.1.0

# Set script args based on env vars from Jenkins parameters
${DRY_RUN} && DRY_RUN_ARG=-n
${FORCE} && FORCE_ARG=-f
${LICENSES_ONLY} && LICENSES_ONLY_ARG=-l
[ ! -z "${PROJECTS}" ] && PROJECTS_ARG="-p ${PROJECTS}"

# We don't need nodejs if we're not injecting header comments
${LICENSES_ONLY} || {

    [ ! -f "./cbdep" ] || ! ./cbdep --version &>/dev/null \
        && echo "Downloading cbdep" \
        && curl http://downloads.build.couchbase.com/cbdep/cbdep.linux -o ./cbdep && chmod 755 ./cbdep

    [ ! -f "./nodejs-${NODE_VERSION}/bin/node" ] \
        && echo "Installing node" \
        && ./cbdep install -d . nodejs ${NODE_VERSION}

    export PATH=$(pwd)/nodejs-${NODE_VERSION}/bin:$PATH
}

./update-bsl-for-manifest \
    ${DRY_RUN_ARG} ${FORCE_ARG} ${LICENSES_ONLY_ARG} ${PROJECTS_ARG} \
    -u "${MANIFEST_REPO}" \
    -m "${MANIFEST}"
