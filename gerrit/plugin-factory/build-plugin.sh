#!/usr/bin/env bash
set -ex

PLUGIN=${1}

# jars are moved to /plugins once they're built, alongside a comma separated
# versions.txt listing each plugin, and the branches/commits used for the build
mkdir -p /plugins

# GERRIT_MAJOR_VERSION is set in the dockerfile, we use that as the
# PLUGIN_MAJOR_VERSION too unless one has been explicitly passed in
PLUGIN_MAJOR_VERSION=${PLUGIN_MAJOR_VERSION:-$GERRIT_MAJOR_VERSION}

function clone_plugin() {
    cd /gerrit/plugins
    rm -rf ${PLUGIN}
    git clone https://gerrit.googlesource.com/plugins/${PLUGIN}
    cd ${PLUGIN}
    if [ -z "${PLUGIN_MINOR_VERSION}" ]
    then
        # If PLUGIN_MINOR_VERSION isn't specified, we just find the most
        # current
        PLUGIN_MINOR_VERSION="[0-9]\+"
    fi
    [ -z "${PLUGIN_BRANCH}" ] && PLUGIN_BRANCH=$(git branch -a | sort -V | grep -e "remotes/origin/stable-${PLUGIN_MAJOR_VERSION}\.${PLUGIN_MINOR_VERSION}$" | tail -n1 | sed 's/.*\///')
    echo "PLUGIN_BRANCH: ${PLUGIN_BRANCH}"
    if [ -z "${PLUGIN_BRANCH}" ]; then
        PLUGIN_BRANCH=master
    fi
    git checkout ${PLUGIN_BRANCH}
}

function checkout_source_tree() {
    cd /gerrit
    if [ -z "${GERRIT_MINOR_VERSION}" ]
    then
        # If GERRIT_MINOR_VERSION isn't specified, we either figure out the
        # GERRIT_BRANCH from the PLUGIN_BRANCH, or set GERRIT_MINOR_VERSION
        # to PLUGIN_MINOR_VERSION (which at this point will either be a
        # specific minor, or a wildcard) and find the branch from there
        if echo "${PLUGIN_BRANCH}" | grep "^stable-${GERRIT_MAJOR_VERSION}\.[0-9]\+$"
        then
            GERRIT_BRANCH="${PLUGIN_BRANCH}"
        else
            GERRIT_MINOR_VERSION="${PLUGIN_MINOR_VERSION}"
        fi
    fi
    [ -z "${GERRIT_BRANCH}" ] && GERRIT_BRANCH=$(git branch -a | sort -V | grep -e "remotes/origin/stable-${GERRIT_MAJOR_VERSION}\.${GERRIT_MINOR_VERSION}$" | tail -n1 | sed 's/.*\///')
    echo "GERRIT_BRANCH: ${GERRIT_BRANCH}"
    git checkout -f ${GERRIT_BRANCH}
    git submodule update --init --recursive
}

function replace_deps_file() {
    # See "Plugins With External Dependencies" section at:
    # https://gerrit-review.googlesource.com/Documentation/dev-build-plugins.html
    cd /gerrit/plugins
    if [ -f "${PLUGIN}/external_plugin_deps.bzl" ]; then
        rm external_plugin_deps.bzl
        ln -s ${PLUGIN}/external_plugin_deps.bzl .
    fi
}

function build_plugin() {
    cd /gerrit
    bazel build plugins/${PLUGIN}:${PLUGIN}
    mv /gerrit/bazel-bin/plugins/${PLUGIN}/${PLUGIN}.jar /plugins
    [ ! -f /plugins/versions.txt ] && echo "plugin name,plugin branch,gerrit branch" >> /plugins/versions.txt
    echo "${PLUGIN},${PLUGIN_BRANCH},${GERRIT_BRANCH}" >> /plugins/versions.txt
}

function tidy_up() {
    rm -rf /usr/local/share/.cache
    rm -rf /root/{.cache,.gerritcodereview,.npm}
    rm -rf /gerrit/tools/node_tools/{yarn.lock,node_modules}
    rm -rf /gerrit/node_modules
}

clone_plugin
checkout_source_tree
replace_deps_file
build_plugin
tidy_up
