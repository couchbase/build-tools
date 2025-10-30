#!/bin/bash

# Ensure ~/.local/bin is on PATH
export PATH=$PATH:$HOME/.local/bin

# Tool name is templated in at build time
TOOL_NAME="__TOOL_NAME__"
SHIM_DIR=~/.local/shims
TOOL_PATH="${SHIM_DIR}/${TOOL_NAME}"

install_tool() {
    # Ensure install directory exists
    mkdir -p "${SHIM_DIR}"
    # Use uv to install/upgrade the tool - we let it install to the
    # default location, but use UV_TOOL_BIN_DIR to dictate where the shim lands
    UV_TOOL_BIN_DIR="${SHIM_DIR}" uv tool install --python-preference=only-managed --reinstall --quiet "${TOOL_NAME}"
}

# If tool isn't already installed, ensure uv is installed and then use
# it to install the tool
if [ ! -x ${TOOL_PATH} ]; then

    # If uv isn't already installed, install it - use curl or wget
    if ! command -v uv 2>&1 >/dev/null; then
        if command -v curl 2>&1 >/dev/null; then
            curl -qLsSf https://astral.sh/uv/install.sh | INSTALLER_PRINT_QUIET=1 sh
        elif command -v wget 2>&1 >/dev/null; then
            wget -qO- https://astral.sh/uv/install.sh | INSTALLER_PRINT_QUIET=1 sh
        else
            echo "Either curl or wget is required to install ${TOOL_NAME}"
            exit 1
        fi
    fi

    install_tool

else

    # If tool is installed but more than a couple days old, update it
    if [[ $(find ${TOOL_PATH} -mtime +2 -print) ]]; then
        install_tool
    fi

fi

# Invoke the tool
exec "${TOOL_PATH}" "$@"

