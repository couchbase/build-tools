# General utility shell functions, useful for any script/product

# Provide a dummy "usage" command for clients that don't define it
type -t usage || usage() {
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

function gover_from_manifest {

    # Try to extract the annotation using "repo" if available, otherwise
    # "xmllint" on "manifest.xml". If neither works, die!
    if test -d .repo && command -v repo > /dev/null; then
        GOVERSION=$(repo forall build -c 'echo $REPO__GOVERSION' 2> /dev/null)
    elif test -e manifest.xml && command -v xmllint > /dev/null; then
        # This version expects "manifest.xml" in the current directory, from
        # either a build-from-manifest source tarball or the Black Duck script
        # running "repo manifest -r".
        GOVERSION=$(xmllint \
            --xpath 'string(//project[@name="build"]/annotation[@name="GOVERSION"]/@value)' \
            manifest.xml)
    else
        echo "Couldn't use repo or xmllint - can't continue!"
        exit 3
    fi

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
