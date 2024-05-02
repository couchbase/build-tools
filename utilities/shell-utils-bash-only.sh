# This file shouldn't be included/sourced directly. It is part of
# shell-utils.sh. It contains those functions which cannot be
# correctly used or parsed by zsh, so that shell-utils.sh itself
# can safely be used by zsh scripts (minus these functions).

# Provide a dummy "usage" command for clients that don't define it
type -t usage > /dev/null || usage() {
    exit 1
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

# Extracts the value of an annotation (converted to ALL_CAPS) from the
# "build" project in the current manifest, using either the 'repo' tool
# (if there's a .repo dir in pwd) or else the 'xmllint' tools (if
# there's a manifest.xml in pwd). If neither tool works, die. If the
# manifest simply doesn't have such an annotation, returns $2 (default "").
function annot_from_manifest {
    annot=$(echo "$1" | tr '[a-z]' '[A-Z]')
    default_value=$2
    # Try to extract the annotation using "repo" if available, otherwise
    # "xmllint" on "manifest.xml". If neither tool works, die!
    if [[ "${OSTYPE}" =~ msys|cygwin ]] && test -d .repo && command -v repo > /dev/null; then
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
    if [ -z "${DEP_VERSION}" ]; then
        echo "${default_value}"
    else
        echo ${DEP_VERSION}
    fi
}
