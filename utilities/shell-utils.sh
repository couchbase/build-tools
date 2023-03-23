# General utility shell functions, useful for any script/product

# Provide a dummy "usage" command for clients that don't define it
type -t usage > /dev/null || usage() {
    exit 1
}

function chk_set {
    var=$1
    # ${!var} is a little-known bashism that says "expand $var and then
    # use that as a variable name and expand it"
    if [[ -z "${!var}" ]]; then
        echo "\$${var} must be set!"
        usage
    fi
}

function header() {
    echo ":::::::::::::::::::::::::::::"
    echo ":: $@"
    echo ":::::::::::::::::::::::::::::"
}

function status() {
    echo "-- $@"
}

function warn() {
    echo "${FUNCNAME[1]}: $@" >&2
}

function error {
    echo "${FUNCNAME[1]}: $@" >&2
    exit 1
}

function chk_cmd {
    for cmd in $@; do
        command -v $cmd > /dev/null 2>&1 || {
            echo "ERROR: command '$cmd' not available!"
            exit 5
        }
    done
}

xtrace_stack=()

# Disable bash's 'xtrace', but remember the current setting so
# it can be restored later with restore_xtrace().
function stop_xtrace() {
    if shopt -q -o xtrace; then
        set +x
        xtrace_stack+=("enabled")
    else
        xtrace_stack+=("disabled")
    fi
}

# Restore bash's 'xtrace', if it was enabled before the most recent
# call to stop_xtrace().
function restore_xtrace() {
    peek="${xtrace_stack[-1]}"
    unset 'xtrace_stack[-1]'
    if [ "${peek}" = "enabled" ]; then
        set -x
    else
        set +x
    fi
}

# Given a fully-qualified Docker image name:tag from a registry,
# returns 0 (success) if the image is available for arm64, or 1
# (failure) otherwise.
function image_has_armarch() {
    # If the image in the registry has an arm64 version, this will
    # display "arm64". Otherwise it will display some other arch. "grep
    # -q" will then set the return value of the function to 0 or 1
    # depending on whether "arm64" is in the output.
    skopeo --override-arch arm64 --override-os linux \
        inspect --format '{{ .Architecture }}' \
        docker://$1 \
        | grep -q arm64
}

# Given a fully-qualified Docker image name:tag from a registry,
# returns 0 (success) if the image exists, or 1 (failure) otherwise.
function image_exists() {
    skopeo --override-os linux inspect docker://$1 &> /dev/null
}

# Provides a unique key string describing an image in a Docker registry.
# If two images have the same key string, then they have the same
# contents. Importantly, if two images have the same key string, then
# copying one to the other will have no effect except possibly modifying
# image digests due to updated timestamps, etc.
function image_key() {
    # Basically we just append the sha256 of the top-most layer of the
    # amd64 image and the sha256 of the top-most layer of the arm64
    # image. If this is not a multi-arch image, that's fine - one
    # sha256 will be an empty string, but that's still unique.
    echo "$(image_arm64_key $1)-$(image_amd64_key $1)"
}

function _image_arch_key() {
    # Helper function for the below - shouldn't be used directly
    arch=$1
    image=$2

    output=()
    output+=($(skopeo --override-arch ${arch} inspect docker://${image} \
        | jq -r '.Architecture + " " + .Layers[-1]'))
    if [ "${output[0]}" != "${arch}" ]; then
        echo ""
    else
        echo "${output[1]/sha256:/}"
    fi
}

# Provides a unique key string describing the arm64 component of a
# multi-arch image. If the image has no arm64 component, returns an
# empty string.
function image_arm64_key() {
    _image_arch_key arm64 $1
}

# Provides a unique key string describing the amd64 component of a
# multi-arch image. If the image has no amd64 component, returns an
# empty string.
function image_amd64_key() {
    _image_arch_key amd64 $1
}

# Extracts the value of an annotation of name "<DEP>_VERSION" from the
# current manifest using either the 'repo' tool (if there's a .repo dir
# in pwd) or else the 'xmllint' tools (if there's a manifest.xml in
# pwd). If neither tool works, die. If the manifest simply doesn't have
# such an annotation, returns "".
function depver_from_manifest {

    DEP=$1

    # Special case since GOVERSION came first
    if [ "${DEP}" = "GO" ]; then
        annot=GOVERSION
    else
        annot=$(echo "${DEP}" | tr '[a-z]' '[A-Z]')_VERSION
    fi

    # Try to extract the annotation using "repo" if available, otherwise
    # "xmllint" on "manifest.xml". If neither works, die!
    if test -d .repo && command -v repo > /dev/null; then
        DEP_VERSION=$(repo forall build -c 'echo $REPO__'${annot} 2> /dev/null)
    elif test -e manifest.xml && command -v xmllint > /dev/null; then
        # This version expects "manifest.xml" in the current directory, from
        # either a build-from-manifest source tarball or the Black Duck script
        # running "repo manifest -r".
        DEP_VERSION=$(xmllint \
            --xpath 'string(//project[@name="build"]/annotation[@name="'${annot}'"]/@value)' \
            manifest.xml)
    else
        echo "Couldn't use repo or xmllint - can't continue!"
        exit 3
    fi

    echo ${DEP_VERSION}
}

function gover_from_manifest {

    GOVERSION=$(depver_from_manifest GO)

    # If the manifest doesn't specify *anything*, do nothing.
    if [ ! -z "${GOVERSION}" ]; then
        # Ok, there's some GOVERSION specified. To ensure we don't break when
        # building older product versions that aren't using the centralized
        # Go version management, if GOVERSION is a fully-specified minor
        # version (eg. "1.18.3"), just use it as-is.
        if [[ ! ${GOVERSION} =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
            # Ok, GOVERSION is a major-only version (eg. "1.18"). Look up the
            # currently supported Go minor version from the 'golang'
            # repository. If the repository isn't there, go grab it.
            if [ ! -d golang ]; then
                GOLANGSHA=$(xmllint \
                    --xpath 'string(//project[@name="golang"]/@revision)' \
                    manifest.xml)
                git clone https://github.com/couchbaselabs/golang
                git -C golang checkout ${GOLANGSHA}
            fi
            # At this point we know the project has "opted in" to
            # the centralized Go version management, therefore it is an error
            # if the specified major version is not supported.
            GOVERFILE=golang/versions/${GOVERSION}.txt
            if [ ! -e "${GOVERFILE}" ]; then
                echo "Specified GOVERSION ${GOVERSION} is not supported!!" >&2
                exit 5
            fi
            GOVERSION=$(cat ${GOVERFILE})
        fi
    fi

    echo ${GOVERSION}
}

# Functions for interacting with the Build Database REST API.
# https://hub.internal.couchbase.com/confluence/display/CR/Build+Database+REST+API
DBAPI_BASE=http://dbapi.build.couchbase.com:8000/v1


# Raw function for calling the build database REST API, for endpoints
# that may return any type of data. Returns the straight JSON response.
function dbapi() {
    path=$1
    filter=$2

    if [ ! -z "${filter}" ]; then
        filter="?filter=${filter}"
    fi
    curl --fail --silent ${DBAPI_BASE}/${path}${filter}
}

# Convenience function for calling the build database REST API for
# endpoints that return simple data - an object with a single key whose
# value is a single string or array of strings.
# Pass an API path (after the leading /v1/) and optionally a filter
# name. Return value will be a newline-separated set of strings matching
# the result.
function dbapi_simple() {
    path=$1
    filter=$2

    # Return just the value of the single top-level object key
    output=$(dbapi ${path} ${filter} | jq -r '.[]')

    # If this output is still an array, process it again
    [[ ${output} = [* ]] && output=$(echo "${output}" | jq -r '.[]')

    echo "${output}"
}

# Even more convenient functions for certain common endpoints.
dbapi_products() {
    dbapi_simple products
}
dbapi_releases() {
    dbapi_simple products/$1/releases
}
dbapi_versions() {
    dbapi_simple products/$1/releases/$2/versions
}
dbapi_builds() {
    # This one can also take a filter
    dbapi_simple products/$1/releases/$2/versions/$3/builds $4
}
