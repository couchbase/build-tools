#!/bin/bash -e

usage() {
    echo "Usage: $0 [--dry-run|--push] [--debug]"
    echo ""
    echo "  (no flag)  Run the checker and report; leaves changes staged for inspection"
    echo "  --dry-run  Run the checker, show the diff that would be proposed, then"
    echo "             restore the working tree"
    echo "  --push     Commit the changes and propose them to Gerrit"
    echo "  --debug    Pass debug logging through to check_new_releases.py"
    exit 1
}

MODE=report
DEBUG_FLAG=
for arg in "$@"; do
    case "$arg" in
        --push)    MODE=push ;;
        --dry-run) MODE=dry-run ;;
        --debug)   DEBUG_FLAG=--debug ;;
        *)         usage ;;
    esac
done

# The checker modifies and stages scan-config.json files in place, and --push
# uses `git commit -am` - so a dirty tree would get swept into the proposed
# change (or make a dry-run restore destructive). Insist on a clean start.
if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree is not clean; commit or stash your changes first." >&2
    exit 1
fi

uv run check_new_releases.py $DEBUG_FLAG

if [ -z "$(git status --porcelain)" ]; then
    echo "No changes detected."
    exit 0
fi

case "$MODE" in
    dry-run)
        echo "Proposed scan-config.json changes:"
        git --no-pager diff --cached
        echo "Dry run: restoring working tree."
        git restore --staged ':/'
        git restore ':/'
        ;;
    push)
        git remote add gerrit ssh://${GERRIT_USER}@review.couchbase.org:29418/build-tools
        git commit -am "Blackduck: add missing versions"
        git push gerrit HEAD:refs/for/master
        echo "Changes have been pushed to Gerrit. Please review the changes at https://review.couchbase.org"
        exit 1
        ;;
    report)
        echo "Changes detected but not pushing. Run with --push to submit to Gerrit,"
        echo "or --dry-run to view the diff and restore the tree automatically."
        ;;
esac
