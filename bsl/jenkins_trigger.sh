#!/bin/bash -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source ${SCRIPT_DIR}/../utilities/shell-utils.sh

NODE_VERSION=17.1.0
GH_VERSION=2.65.0

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

# Set up environment for scripts: set GH_TOKEN, install cbdep, install
# gh. The `gh` tool will honor the GH_TOKEN env var for authentication.
# It's safer to use that here rather than `gh auth login` because the
# latter updates the Unix user's global settings, which is an
# unnecessary risk for a shared environment like a Jenkins agent.
stop_xtrace
export GH_TOKEN=$(cat ~/.ssh/cb-robot-bsl-jenkins-token)
restore_xtrace

uv tool install --upgrade cbdep
cbdep install -d tools gh ${GH_VERSION}
export PATH=$(pwd)/tools/gh-${GH_VERSION}/bin:$PATH

for mani in ${MANIFESTS}; do

    product=$(dirname ${mani})
    # Skip manifest if `do-build` is explicitly false. `do-build` is
    # used by `scan-manifests` to determine which manifests to
    # automatically poll, and that script assumes the default value is
    # `True`, so we do the same here.
    do_build=$(cat manifests/${product}/product-config.json | jq '.manifests."'${mani}'"."do-build"')
    if [ "${do_build}" = "false" ]; then
        header "${mani}: Skipping because 'do-build' is false"
    else
        ./update-bsl-for-manifest \
            ${DRY_RUN_ARG} ${LICENSES_ONLY_ARG} ${PROJECTS_ARG} \
            -u "${MANIFEST_REPO}" \
            -m "${mani}"
    fi

done

status "All done!"
