# General utility shell functions, useful for any script/product
#
# Note that this is generally intended for use by bash scripts but
# should at least be parseable by zsh. If you need to add a function
# that doesn't work properly in zsh, add it to shell-utils-bash-only.sh

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
    echo
    echo ":::::::::::::::::::::::::::::"
    echo ":: $@"
    echo ":::::::::::::::::::::::::::::"
    echo
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

function version_lt() {
    [ "${1}" = "${2}" ] && return 1 || [  "${1}" = "$(printf "${1}\n${2}" | sort -V | head -n1)" ]
}


####
# Certain functions that only work in bash, not zsh
####

if [ -n "$BASH_VERSINFO" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/shell-utils-bash-only.sh"
fi

####
# End bash-only functions
####

function repo_init() {
    # Performs a "repo init", but first does an init --mirror and sync
    # in ~/.reporef before doing the actual repo init with --reference
    # ~/.reporef. This caches the git history, making later `repo sync`
    # operations much faster.
    #
    # Note: This supports the -u, -b, -g, and -m options of `repo init`.

    # Read the options using getopts. Unsetting OPTIND is necessary to
    # allow multiple calls to this function in the same script.
    unset OPTIND
    local url manifest
    local branch=master
    local groups=default
    while getopts "u:b:g:m:" opt; do
        case $opt in
            u) url=$OPTARG;;
            b) branch=$OPTARG;;
            g) groups=$OPTARG;;
            m) manifest=$OPTARG;;
            *) echo "Invalid argument $opt"
               exit 1;;
        esac
    done
    chk_set url manifest

    local mirror_arg=""
    if [ ! -d ~/.reporef ]; then
        mkdir ~/.reporef
        # `repo` only allows specifying `--mirror` on a clean directory,
        # but it will continue to honor it on subsequent re-inits in
        # that directory
        mirror_arg="--mirror"
    fi
    pushd ~/.reporef
    repo init ${mirror_arg} -u ${url} -b ${branch} -g ${groups} -m ${manifest}
    repo sync -j8
    popd

    repo init --reference ~/.reporef -u ${url} -b ${branch} -g ${groups} -m ${manifest}
}

function clean_git_clone() {
    # Does everything possible to ensure that a given directory looks
    # like a freshly-cloned git repository, including having a remote
    # named 'origin' pointing to the specified URL; being checked out to
    # a local branch with the same name as the repository's default
    # branch, tracking that remote branch; and with no local changes
    local gitrepo=$1
    local outdir=$2

    if [ -z "${outdir}" ]; then
        outdir=$(basename "${gitrepo}")
    fi

    # Create dir if not already there
    if [ ! -d "${outdir}" ]; then
        mkdir -p "${outdir}"
    fi
    pushd "${outdir}"

    # Initialize fresh git repository if not already one
    if [ ! -d ".git" ]; then
        # Need to specify some default branch name to avoid warnings
        git init -b main
    fi

    # Point 'origin' to the git repository and fetch changes
    curr=$(git config --local --default="unset" --get remote.origin.url)
    if [ "${curr}" = "unset" ]; then
        git remote add origin "${gitrepo}"
    elif [ "${curr}" != "${gitrepo}" ]; then
        git remote set-url origin "${gitrepo}"
    fi
    git fetch origin

    # Ensure we're up-to-date with the remote's default branch
    git remote set-head origin --auto
    default_branch=$(basename $(git rev-parse --abbrev-ref origin/HEAD))

    # Wipe all local changes
    git reset --hard
    git clean -dfx

    # Create new local branch with correct name and check it out
    git checkout -B ${default_branch} --track origin/${default_branch}

    popd
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
    # Basically we just append the key of the amd64 image and the key of
    # the arm64 image. If this is not a multi-arch image, that's fine -
    # one sha256 will be an empty string, but that's still unique.
    echo "$(image_arm64_key $1)-$(image_amd64_key $1)"
}

function _image_arch_key() {
    # Helper function for the below - shouldn't be used directly
    arch=$1
    image=$2

    output=()
    # Several interesting things going on here.
    #
    # 1. `skopeo inspect` won't fail if you specify, say,
    #    `--override-arch arm64` and the image is a single-arch amd64
    #    image; it will just return the details of the amd64 image.
    #    Since those details *do* include the arch, we capture that and
    #    compare it to the requested arch. If they're not the same, we
    #    just return an empty string key.
    # 2. Docker uses "content-addressable IDs", which means they only
    #    contain filesystem/metadata diffs. As such, it's quite possible
    #    for two different images to share a layer SHA. One common way
    #    this can occur is with the `ENTRYPOINT` directive - that only
    #    affects metadata and has no timestamp information, so basically
    #    *every* image that has the same `ENTRYPOINT ["foo"]` will share
    #    the same layer SHA. Since `ENTRYPOINT` is frequently the last
    #    directive in a Dockerfile, that means it's not at all uncommon
    #    for two different images to share the same top layer. This is
    #    unlike git, where if you see the same commit SHA in two places,
    #    you can be completely sure that the entire history of those two
    #    places is also identical.
    #
    # The upshot is that if we want to check to see if two images on a
    # remote registry are "the same", we have to compare their entire
    # set of layer SHAs. To do this we gather them all, sort them, and
    # form our own sha256 checksum of that list.
    output+=(
        $(skopeo --override-arch ${arch} \
        inspect docker://${image} \
        --format '{{.Architecture}}{{range .Layers}} {{.}}{{end}}')
    )
    if [ "${output[0]}" != "${arch}" ]; then
        echo ""
    else
        printf '%s\n' "${output[@]:1}" | sort | sha256sum | cut -c -64
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

# Extracts the value of the GOVERSION or GO_VERSION annotation from the
# current manifest, and maps it to a full Golang version utilizing
# centralized Go version management (github.com/couchbaselabs/golang).
function gover_from_manifest {

    # This functionality is duplicated in the golang repo, so if that
    # is available, use it directly.
    if [ -x golang/util/get-go-ver.sh ]; then
        golang/util/get-go-ver.sh
        return
    fi

    # Leave this duplicate code here for now, to support products using
    # older versions of that repo

    # This is unfortunately spelled two different ways in different
    # products' manifests (CBD-5117), and fixing that would be
    # potentially disruptive, so just look for either. As far as I know
    # no product uses *both* spellings, but if they do, "GOVERSION" will
    # win.
    GOVERSION=$(annot_from_manifest GOVERSION)
    if [ -z "${GOVERSION}" ]; then
        GOVERSION=$(annot_from_manifest GO_VERSION)
    fi

    # If the manifest doesn't specify *anything*, do nothing.
    if [ -z "${GOVERSION}" ]; then
        return
    fi

    # Ok, there's some GOVERSION specified. To ensure we don't break when
    # building older product versions that aren't using the centralized
    # Go version management, if GOVERSION is a fully-specified minor
    # version (eg. "1.18.3"), just use it as-is.
    if [[ ${GOVERSION} =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo ${GOVERSION}
        return
    fi

    # Ok, GOVERSION is something that needs to be resolved through the
    # centralized Go version management. Ensure that the 'golang'
    # repository is available - this function is sometimes used where we
    # have a manifest but not the entire repo sync.
    if [ ! -d golang ]; then
        GOLANGSHA=$(xmllint \
            --xpath 'string(//project[@name="golang"]/@revision)' \
            manifest.xml)
        git clone https://github.com/couchbaselabs/golang
        git -C golang checkout ${GOLANGSHA} &>/dev/null
    fi

    # If it's SUPPORTED_NEWER/OLDER, determine corresponding major version.
    if [[ ${GOVERSION} =~ SUPPORTED_(NEWER|OLDER) ]]; then
        GOVERSION=$(cat golang/versions/${GOVERSION}.txt)
    fi

    # By now, GOVERSION should be a X.Y version. Look up the currently
    # supported Go minor version from the 'golang' repository. At this
    # point we know the project has "opted in" to the centralized Go
    # version management, therefore it is an error if the specified
    # major version is not supported.
    GOVERFILE=golang/versions/${GOVERSION}.txt
    if [ ! -e "${GOVERFILE}" ]; then
        echo "Specified GOVERSION ${GOVERSION} is not supported!!" >&2
        exit 5
    fi
    GOVERSION=$(cat ${GOVERFILE})

    echo ${GOVERSION}
}

# Functions for interacting with the Build Database REST API.
# https://confluence.issues.couchbase.com/wiki/spaces/CR/pages/2405402249/Build+Database+REST+API
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
