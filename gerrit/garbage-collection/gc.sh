#!/bin/bash -e
#
# Gerrit repository garbage collection
#
# Runs GC on Gerrit repositories by:
# 1. Temporarily setting repos to READ_ONLY state
# 2. Running gerrit gc
# 3. Restoring original state
# 4. Cleaning up on interrupt/exit
#
# Usage:
#   ./gc.sh [repo-name]    # GC a single repository
#   ./gc.sh                # GC all non-excluded repos

repo=$1

if [ $# -gt 1 ]; then
    echo "Usage: $0 [repo-name]"
    exit 1
fi

gerrit_host="gerrit-garbage-collection"
excluded_repos="-NorthScale-|-membase-|-readonly-|-sdks-|All-Projects|All-Users"

current_repo=""
trap 'cleanup_readonly' EXIT

function cleanup_readonly() {
    if [ -n "$current_repo" ]; then
        echo "Disabling READ_ONLY on repository left in READ_ONLY state: $current_repo"
        ssh ${gerrit_host} gerrit set-project --project-state ACTIVE -- "$current_repo" || true
    fi
}

function gerrit_gc() {
    repo=$1

    # Check current project state using native filtering
    if ssh ${gerrit_host} gerrit ls-projects --state READ_ONLY --match "${repo}" | grep -q -- "^${repo}$"; then
        echo "Skipping $repo - already in READ_ONLY state"
        return 0
    fi

    current_repo="$repo"

    echo "Setting $repo to READ_ONLY"
    if ! ssh ${gerrit_host} gerrit set-project --project-state READ_ONLY -- "$repo"; then
        echo "ERROR: Failed to set $repo to READ_ONLY"
        exit 1
    fi

    echo "Running gerrit gc on repository $repo"
    if ssh ${gerrit_host} gerrit gc -- "$repo"; then
        echo "Garbage collection on $repo successful"
    else
        echo "ERROR: Garbage collection on $repo failed!"
        exit 1
    fi

    echo "Setting $repo back to ACTIVE"
    if ssh ${gerrit_host} gerrit set-project --project-state ACTIVE -- "$repo"; then
        current_repo=""
    else
        echo "ERROR: Failed to set $repo to ACTIVE"
        exit 1
    fi
}

function repos() {
    all_repos=$(ssh ${gerrit_host} gerrit ls-projects)
    echo "$all_repos" | grep -Ev -- "$excluded_repos"
}

function check_readonly_plugin() {
    printf "Checking if readonly plugin is enabled... "
    if ! ssh ${gerrit_host} gerrit plugin ls | grep -qE '^readonly\s+\S+\s+\S+\s+ENABLED\b'; then
        echo "FAILED"
        exit 1
    else
        echo "OK"
    fi
}

check_readonly_plugin

if [ "$repo" != "" ]; then
    gerrit_gc "$repo"
else
    for repo in $(repos); do
        gerrit_gc "$repo"
    done
fi
