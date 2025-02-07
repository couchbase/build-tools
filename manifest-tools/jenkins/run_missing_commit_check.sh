#!/bin/sh -e

show_help(){
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --product <product>                The product to check"
    echo "  --project <project/s>              Comma separated list of projects to check"
    echo "  --first-manifest <first_manifest[:build_number]>  The first manifest (optional)"
    echo "  --last-manifest <last_manifest[:build_number]>    The last manifest (optional)"
    echo "  --only-boundaries                  Only check the first and last manifests, no intermediate ones"
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

ARGS=$(getopt -o h -l help,product:,project:,first-manifest:,last-manifest:,test-email:,only-boundaries,show-matches,no-sync,notify,debug -- "$@")

if [ $? -ne 0 ]; then
    echo "Failed to parse arguments"
    exit 1
fi

eval set -- "$ARGS"

SYNC=true

while true; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --product)
            PRODUCT=$2
            shift 2
            ;;
        --project)
            PROJECT_ARG="--project $2"
            shift 2
            ;;
        --first-manifest)
            if [[ "${2}" = *":"* ]]; then
                manifest="${2%%:*}"
                build="${2#*:}"
                FIRST_BUILD="$build"
            else
                manifest="${2}"
            fi
            FIRST_MANIFEST="$manifest"
            FIRST_CODENAME="${manifest#*/}"
            FIRST_CODENAME="${FIRST_CODENAME%%/*}"
            FIRST_VERSION="${manifest##*/}"
            FIRST_VERSION="${FIRST_VERSION%.*}"
            FIRST_MANIFEST_ARG="--first_manifest $FIRST_MANIFEST"
            shift 2
            ;;
        --last-manifest)
            if [[ "${2}" = *":"* ]]; then
                manifest="${2%%:*}"
                build="${2#*:}"
                LAST_BUILD="$build"
            else
                manifest="${2}"
            fi
            LAST_MANIFEST="$manifest"
            LAST_CODENAME="${manifest#*/}"
            LAST_CODENAME="${LAST_CODENAME%%/*}"
            LAST_VERSION="${manifest##*/}"
            LAST_VERSION="${LAST_VERSION%.*}"
            LAST_MANIFEST_ARG="--last_manifest $LAST_MANIFEST"
            shift 2
            ;;
        --only-boundaries)
            ONLY_BOUNDARIES_ARG="--only_boundaries"
            shift
            ;;
        --test-email)
            TEST_EMAIL_ARG="--test_email $2"
            shift 2
            ;;
        --notify)
            NOTIFY_ARG="--notify"
            shift
            ;;
        --debug)
            DEBUG_ARG="-d"
            shift
            ;;
        --show-matches)
            SHOW_MATCHES_ARG="--show_matches"
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

if [ ! -z "${NOTIFY_ARG}" -a -z "${SLACK_OAUTH_TOKEN}" ]; then
    echo "SLACK_OAUTH_TOKEN not set"
    exit 1
fi

if [ "$PRODUCT" = "" ]; then
    echo "ERROR: --product is required"
    exit 1
fi

if [ \( -n "${FIRST_BUILD}" -a -z "${LAST_BUILD}" \) -o \( -z "${FIRST_BUILD}" -a -n "${LAST_BUILD}" \) ]; then
    echo "[ERROR] Specific builds can only be compared to specific builds"
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

build_manifest_dir="${manifests_dir}/build-manifests"
build_manifest_repo=ssh://git@github.com/couchbase/build-manifests

if ${SYNC}; then
    cd ${manifests_dir}
    echo "Cloning manifest repo ${manifest_repo}..."
    rm -rf ${manifest_dir}
    git clone ${manifest_repo} > /dev/null

    echo "Cloning build-manifest repo ${build_manifest_repo}..."
    rm -rf ${build_manifest_dir}
    git clone ${build_manifest_repo} > /dev/null

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

# If we're processing specific builds, we add new `from` and `to` manifests
# to the manifest dir and pass those in as the first and last manifest along
# with the --compare_builds flag
if [ "${FIRST_BUILD}" != "" ]; then
    pushd ${build_manifest_dir}
    FIRST_SHA=$(git log --grep="${PRODUCT} ${FIRST_CODENAME} build ${FIRST_VERSION}-${FIRST_BUILD}" --format="%H")
    LAST_SHA=$(git log --grep="${PRODUCT} ${LAST_CODENAME} build ${LAST_VERSION}-${LAST_BUILD}" --format="%H")

    set -x
    git checkout ${FIRST_SHA} > /dev/null
    cp "${FIRST_MANIFEST}" "${manifest_dir}/checker-from.xml"
    FIRST_MANIFEST_ARG="--first_manifest ${manifest_dir}/checker-from.xml"

    git checkout ${LAST_SHA} > /dev/null
    cp "${LAST_MANIFEST}" "${manifest_dir}/checker-to.xml"
    LAST_MANIFEST_ARG="--last_manifest ${manifest_dir}/checker-to.xml"
    popd
    COMPARE_BUILDS_ARG="--compare_builds"
    set +x
fi

echo
echo "Checking for missing commits in ${PRODUCT}...."
echo

cd ${release_dir}

failed=0

PYTHONUNBUFFERED=1 find_missing_commits \
    $DEBUG_ARG \
    $SHOW_MATCHES_ARG \
    $NOTIFY_ARG \
    $TEST_EMAIL_ARG \
    $PROJECT_ARG \
    $FIRST_MANIFEST_ARG \
    $LAST_MANIFEST_ARG \
    $ONLY_BOUNDARIES_ARG \
    $COMPARE_BUILDS_ARG \
    --manifest_repo ${manifest_repo} \
    --reporef_dir ${reporef_dir} \
    --manifest_dir ${manifest_dir} \
    ${PRODUCT}
failed=$(($failed + $?))

exit $failed
