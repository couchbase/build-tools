#!/bin/bash -e

# Function to update and push podspec
cocoa_push() {
    local podspec="${1}"
    echo "Updating podspec: ${podspec}"

    sed -i \
        -e "/s\.version/ s/'[^']*'/'${VERSION}'/" \
        -e "/s\.source/ s/\([0-9]\+\.[0-9]\+\.[0-9]\+\)/${VERSION}/g" \
        -e "/s\.ios\.deployment_target/ s/'[^']*'/'${ios_target}'/" \
        -e "/s\.osx\.deployment_target/ s/'[^']*'/'${osx_target}'/" \
        ${podspec}

    pod spec lint ${podspec}

    # Push to trunk if not in dry-run mode
    if [[ "${DRYRUN}" == 'false' ]]; then
        # Extract pod name from podspec filename (remove .podspec extension)
        local pod_name="${podspec%.podspec}"

        # Check if version is already published on trunk
        if pod trunk info "${pod_name}" 2>/dev/null | grep -q "${VERSION}"; then
            echo "Skipping publish: ${pod_name} version ${VERSION} already published"
        else
            echo "Publish ${podspec}"
            # pod trunk push intermittently fails with a transient
            # "internal server error" from the CocoaPods trunk service even
            # though the push completed server-side; a naive retry then hits
            # a 409 "duplicate entry" for a version that's actually already
            # published. Treat that response as success instead of retrying.
            local max_attempts=5
            local attempt=1
            local log_file
            log_file="$(mktemp)"
            while true; do
                pod trunk push "${podspec}" --verbose 2>&1 | tee "${log_file}"
                push_status=${PIPESTATUS[0]}
                if (( push_status == 0 )); then
                    break
                fi
                if grep -q "Unable to accept duplicate entry" "${log_file}"; then
                    echo "${pod_name} version ${VERSION} is already published on trunk, treating as success"
                    break
                fi
                if (( attempt >= max_attempts )); then
                    echo "Failed to publish ${podspec} after ${attempt} attempts"
                    rm -f "${log_file}"
                    exit 1
                fi
                echo "pod trunk push failed (attempt ${attempt}/${max_attempts}), retrying in 30s..."
                sleep 30
                ((attempt++))
            done
            rm -f "${log_file}"
        fi
    else
        echo "DRYRUN mode: ${podspec}"
        cat "${podspec}"
    fi
}

# Create PR to update couchbase-lite-ios CE podspecs
create_pr() {
    local repo="${1}"
    pushd ${SCRIPT_DIR}/${repo}
    git checkout ${BRANCH}
    git branch podspecs_update
    git checkout podspecs_update
    for podspec in *.podspec; do
        sed -i \
            -e "/^\s*s\.version/ s/'[^']*'/'${VERSION}'/" \
            -e "/s\.ios\.deployment_target/ s/'[^']*'/'${ios_target}'/" \
            -e "/s\.osx\.deployment_target/ s/'[^']*'/'${osx_target}'/" \
            ${podspec}
    done
    if [[ -z $(git status -s) ]]; then
        echo "Podspecs are up-to-date.  No need to raise PR."
    else
        git commit -a -m "Update pod specs for ${PRODUCT} ${VERSION}"

        if [[ "${DRYRUN}" == 'false' ]]; then
            gh pr create --repo "${repo}" --base "${BRANCH}" -f
        fi
    fi
    popd
}

# set environment variables for Ruby
set_ruby_env() {
    ### zz-lightweight for mobile comes w/ rvm installed
    ### rvm install will skip installation if desired version is already installed
    sudo chown -R couchbase:couchbase /usr/share/rvm
    source /etc/profile.d/rvm.sh
    rvmsudo rvm install "${RUBY_VERSION}"
    rvm --default use "${RUBY_VERSION}"
    rvmsudo gem install cocoapods
    rvmsudo gem update cocoapods
    export LANG=en_US.UTF-8
    export PATH="/usr/share/rvm/rubies/ruby-${RUBY_VERSION}/bin:/usr/share/rvm/gems/ruby-${RUBY_VERSION}/bin:$PATH"
}

# Ensure there is an active pod session.
# Refers to the confluence page if a new session needs to be initiated
# https://confluence.issues.couchbase.com/wiki/spaces/CR/pages/2405402255/Mobile+-+Build+and+Release+Process
verify_pod_session() {
    echo "Importing GPG keys..."
    sudo gpg --keyserver keyserver.ubuntu.com \
        --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
    echo "Listing current pod session, if any ..."
    pod trunk me || exit 1
}

couchbase_lite_ios_publish() {
    # Clone repositories and process podspecs
    git clone git@github.com:couchbaselabs/couchbase-lite-ios-ee.git
    git clone git@github.com:couchbase/couchbase-lite-ios.git

    # Figure out deployment targets
    # CBD-6346, starting from 3.3, xcconfig file has been changed to CBL_OS_Target_Versions.xcconfig
    pushd couchbase-lite-ios
    git checkout ${BRANCH}
    if [[ "$(printf '%s\n' "$VERSION" "3.3" | sort -V | head -n1)" != "3.3" ]]; then
        xc_config="Project.xcconfig"
    else
        xc_config="CBL_OS_Target_Versions.xcconfig"
    fi
    ios_target=$(cat ${SCRIPT_DIR}/couchbase-lite-ios/xcconfigs/${xc_config} |grep IPHONEOS_DEPLOYMENT_TARGET |awk '{print $3}')
    osx_target=$(cat ${SCRIPT_DIR}/couchbase-lite-ios/xcconfigs/${xc_config} |grep MACOSX_DEPLOYMENT_TARGET |awk '{print $3}')

    if [[ -z "$ios_target" || -z "$osx_target" ]]; then
        echo "Error: Unable to determine deployment target(s) in ${xc_config}:"
        echo "IPHONEOS_DEPLOYMENT_TARGET is: ${ios_target}"
        echo "MACOSX_DEPLOYMENT_TARGET is: ${osx_taget}"
        exit 1
    fi
    popd

    pushd couchbase-lite-ios-ee/Podspecs
    git checkout ${BRANCH}
    if [[ "${COMMUNITY}" != "no" ]]; then
        files=$(ls *.podspec)
    else
        files=$(ls *.podspec |grep Enterprise)
    fi
    echo "podspecs: ${files}"
    for file in ${files}; do
        cocoa_push "${file}"
    done
    popd
}

couchbase_lite_vector_search_publish() {
    repo="couchbaselabs/mobile-vector-search.git"
    git clone git@github.com:${repo}
    pushd mobile-vector-search/podspec
    git checkout "${BRANCH}"
    for file in *.podspec; do
        cocoa_push "${file}"
    done
    popd
}

# Main

# Predefined params from Jenkins job:
# ${PRODUCT}, ${VERSION}, ${DRYRUN}, ${BRANCH}, ${COMMUNITY}, ${RUBY_VERSION}

set_ruby_env

# Ensure there is a valid pod session before continue
verify_pod_session

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd ${SCRIPT_DIR}

case "${PRODUCT}" in
    couchbase-lite-ios)
        couchbase_lite_ios_publish
        ;;
    couchbase-lite-vector-search)
        couchbase_lite_vector_search_publish
        ;;
    *)
        echo "Invalid product: ${PRODUCT}"
        exit 1
        ;;
esac
