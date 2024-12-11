#!/bin/bash -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source ${SCRIPT_DIR}/../utilities/shell-utils.sh

NODE_VERSION=17.1.0

# Set script args based on env vars from Jenkins parameters
${DRY_RUN} && DRY_RUN_ARG=-n
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

if [ "${MANIFEST}" = "ALL" ]; then
    header "Checking and updating all manifests"
    clean_git_clone ${MANIFEST_REPO} manifests
    cd manifests

    # This 'find' will catch all manifests in top-level product
    # directories, eg. couchbase-server and couchbase-lite-core, while
    # skipping any in the 'toy' or 'released' directories
    MANIFESTS=$( \
        find * -maxdepth 1 \
            -name toy -prune -o -name released -prune -o \
            -name '*.xml' -print0 | \
        xargs -0 grep -E -sl -e BSL_PRODUCT \
    )

    cd ..
else
    MANIFESTS=${MANIFEST}
fi

for mani in ${MANIFESTS}; do
    header "Checking and updating ${mani}"
    ./update-bsl-for-manifest \
        ${DRY_RUN_ARG} ${LICENSES_ONLY_ARG} ${PROJECTS_ARG} \
        -u "${MANIFEST_REPO}" \
        -m "${mani}"
done

status "All done!"
