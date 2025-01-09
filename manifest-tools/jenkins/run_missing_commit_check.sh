#!/bin/sh -e

show_help(){
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --product <product>                The product to check"
    echo "  --project <project/s>              Comma separated list of projects to check"
    echo "  --first-manifest <first_manifest>  The first manifest (optional)"
    echo "  --last-manifest <last_manifest>    The last manifest (optional)"
    echo "  --test-email <user@domain.com>     Send all slack messages to this user for testing (use with --notify)"
    echo "  --notify                           Send slack notifications to users"
    echo "  --debug                            Enable debug output"
    echo "  --show-matches                     Show matched commits as well as unmatched"
    echo "  --no-sync                          Do not synchronise repositories (useful for debugging)"
    echo "  -h, --help                         Display this help and exit"
}

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

ARGS=$(getopt -o h -l help,product:,project:,first-manifest:,last-manifest:,test-email:,show-matches,no-sync,notify,debug -- "$@")

if [ $? -ne 0 ]; then
    echo "Failed to parse arguments"
    exit 1
fi

eval set -- "$ARGS"

SYNC=true

while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--product <product>] [--project <project/s>] [--first-manifest <first_manifest>] [--last-manifest <last_manifest>] [--test-email <user@domain.com>] [--show-matches] [--notify] [--no-sync] [--debug]"
            exit 0
            ;;
        --product)
            PRODUCT=$2
            shift 2
            ;;
        --project)
            PROJECT="--project $2"
            shift 2
            ;;
        --first-manifest)
            FIRST_MANIFEST="--first_manifest $2"
            shift 2
            ;;
        --last-manifest)
            LAST_MANIFEST="--last_manifest $2"
            shift 2
            ;;
        --test-email)
            TEST_EMAIL="--test_email $2"
            shift 2
            ;;
        --notify)
            NOTIFY="--notify"
            shift
            ;;
        --debug)
            DEBUG="-d"
            shift
            ;;
        --show-matches)
            SHOW_MATCHES="--show_matches"
            shift
            ;;
        --no-sync)
            SYNC=false
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$PRODUCT" = "" ]; then
    echo "ERROR: --product is required"
    exit 1
fi

reporef_dir=/data/reporef
metadata_dir=/data/metadata
manifests_dir=/data/manifests

# Update reporef. Note: This script requires /home/couchbase/reporef
# to exist in two places, with that exact path:
#  - The Docker host (currently mega3), so it's persistent
#  - Mounted in the Jenkins agent container, so this script can be run
#    to update it
# It is then mounted into the container running this script as
# /data/reporef Remember that when passing -v arguments to "docker run"
# from within a container (like the Jenkins agent), the path is
# interpreted by the Docker daemon, so the path must exist on the
# Docker *host*.
if [ -z "$(ls -A $reporef_dir)" ]
then
    cd "${reporef_dir}"
    if [ ! -e .repo ]; then
        # This only pre-populates the reporef for Server git code. Might be able
        # to do better in future.
        echo "Initialising repo in ${reporef_dir}..."
        repo init -u ssh://git@github.com/couchbase/manifest -g all -m branch-master.xml
    fi
fi

if [ "$PRODUCT" = "sync_gateway" ]; then
    manifest_dir="${manifests_dir}/sync_gateway"
    manifest_repo=ssh://git@github.com/couchbase/sync_gateway
else
    manifest_dir="${manifests_dir}/manifest"
    manifest_repo=ssh://git@github.com/couchbase/manifest
fi

if ${SYNC}; then
    cd ${manifests_dir}
    echo "Cloning manifest repo ${manifest_repo}..."
    rm -rf ${manifest_dir}
    git clone ${manifest_repo} > /dev/null

    cd "${reporef_dir}"
    echo "Syncing manifest"

    # Run a repo sync, ensuring that any lines containing the text "Bad configuration option: setenv" are suppressed
    repo sync --jobs=6 -q 2>&1 | grep -v "Bad configuration option: setenv" || :

    cd "${metadata_dir}"

    # This script also expects a /home/couchbase/check_missing_commits to be
    # available on the Docker host, and mounted into the Jenkins agent container
    # at /data/metadata, for basically the same reasons as above.
    # Note: I tried initially to use a named Docker volume for this
    # to avoid needing to create the directory on the host; however, Docker kept
    # changing the ownership of the mounted directory to root in that case.

    rm -rf product-metadata
    echo "Cloning product-metadata repo..."
    git clone ssh://git@github.com/couchbase/product-metadata > /dev/null
fi

echo
echo "Checking for missing commits in ${PRODUCT}...."
echo

cd ${release_dir}

failed=0

PYTHONUNBUFFERED=1 find_missing_commits \
    $DEBUG \
    $SHOW_MATCHES \
    $NOTIFY \
    $TEST_EMAIL \
    $PROJECT \
    $FIRST_MANIFEST \
    $LAST_MANIFEST \
    --manifest_repo ${manifest_repo} \
    --reporef_dir ${reporef_dir} \
    --manifest_dir ${manifest_dir} \
    ${PRODUCT}
failed=$(($failed + $?))

exit $failed
