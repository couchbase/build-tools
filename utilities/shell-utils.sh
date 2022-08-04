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

    # This function expects "manifest.xml" in the current directory, from
    # either a build-from-manifest source tarball or the Black Duck script
    # running "repo manifest -r". Fail with clear error if that's missing.
    if [ ! -e manifest.xml ]; then
        echo "Need to have manifest.xml in current directory!"
        exit 3
    fi

    # Extract Golang version to use from manifest
    GOANNOTATION=$(xmllint \
        --xpath 'string(//project[@name="build"]/annotation[@name="GOVERSION"]/@value)' \
        manifest.xml)
    GOVERSION=${GOANNOTATION}

    # If the manifest doesn't specify *anything*, do nothing.
    if [ ! -z "${GOVERSION}" ]; then
        # Ok, there's some GOVERSION specified. To ensure we don't break when
        # building older product versions that aren't using the centralized
        # Go version management, if GOVERSION is a fully-specified minor
        # version (eg. "1.18.3"), just use it as-is.
        if [[ ! ${GOVERSION} =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
            # Ok, GOVERSION is a major-only version (eg. "1.18"). Look up the
            # currently supported Go minor version from the 'golang'
            # repository. At this point we know the project has "opted in" to
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