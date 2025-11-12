#!/bin/bash -ex

# Install Nodejs
install_nodejs() {
    NODE_VERSION=$(curl -s https://nodejs.org/dist/index.json | \
        jq -r '.[] | select(.lts != false) | .version' | \
        head -1 | sed 's/^v//')
    cbdep install nodejs ${NODE_VERSION}
    export PATH=`pwd`/install/nodejs-${NODE_VERSION}/bin:${PATH}
}

# Validate npmrc for registry authentication
validate_npmrc() {
    local registry=$1

    # Create or update ~/.npmrc
    if [[ ! -f ~/.npmrc ]]; then
        echo "Creating ~/.npmrc"
        chk_set NPM_TOKEN
        cat > ~/.npmrc << EOF
always-auth=true
//${registry}/:_authToken=${NPM_TOKEN}
EOF
    elif ! grep -q "always-auth=true" ~/.npmrc; then
        echo "always-auth=true" >> ~/.npmrc
    fi

    # Verify configuration based on registry type
    case "${registry}" in
        *registry.npmjs.org*)
            npm whoami --registry="${registry}" >/dev/null 2>&1 || {
                echo "Error: ~/.npmrc is not configured for ${registry}"
                exit 1
            }
            ;;
        *)
            grep -q "${registry}" ~/.npmrc || {
                echo "Error: ~/.npmrc is not configured for ${registry}"
                exit 1
            }
            ;;
    esac
}

# Download package from internal proget
# Then publish to npmjs
# Assume the packages should be publicly available
# We don't have a pay account to host private packages
publish() {
    proget_registry="https://proget.sc.couchbase.com/npm/cbl-npm/"
    npmjs_registry="https://registry.npmjs.org/"
    validate_npmrc ${npmjs_registry}

    # Download version with build number from internal registry (e.g., 1.2.3-123)
    # Strip build number from version and publish to npmjs.org
    npm pack ${NPMJS_PKG}@${VERSION}-${BLD_NUM} --registry=${proget_registry}
    tar -xzf ${PKG_NAME}-${VERSION}-${BLD_NUM}.tgz
    pushd package
    jq --arg ver "${VERSION}" '.version = $ver' package.json > package.json.tmp
    mv package.json.tmp package.json
    npm pack
    npm publish ${PKG_NAME}-${VERSION}.tgz --ignore-scripts --registry=${npmjs_registry} --access public
}

# Main
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM
if [[ -n ${NPMJS_ORG} ]]; then
    NPMJS_PKG="@${NPMJS_ORG}/${PRODUCT}"
    PKG_NAME="${NPMJS_ORG}-${PRODUCT}"
else
    NPMJS_PKG="${PRODUCT}"
    PKG_NAME="${PRODUCT}"
fi
install_nodejs
publish
