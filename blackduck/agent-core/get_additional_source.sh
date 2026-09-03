#!/bin/bash -ex

SOURCE_DIR=agent-core

# UV detector is introduced in 10.5.0
# Don't clobber a newer version if Jenkins has a newer default
MIN_DETECT_JAR_VERSION=10.5.0
if [ -z "${DETECT_JAR_VERSION}" ] || [ "$(printf '%s\n' "${MIN_DETECT_JAR_VERSION}" "${DETECT_JAR_VERSION}" | sort -V | head -n1)" != "${MIN_DETECT_JAR_VERSION}" ]; then
    DETECT_JAR_VERSION=${MIN_DETECT_JAR_VERSION}
fi
export DETECT_JAR_VERSION

# detect.uv.path (set in detect-config.json) points Detect's UV detector at
# whichever uv binary UV_BIN_PATH resolves to. Use the agent's default uv
# unless the Jenkins job has already set UV_BIN_PATH to pin a specific one
# for this scan.
UV_BIN_PATH="${UV_BIN_PATH:-$(command -v uv)}"
export UV_BIN_PATH

# Match the interpreter version the real build uses (see Makefile's
# PYTHON_VERSION). Install it explicitly and pin it as a local
# ".python-version" file inside agent-core, rather than exporting
# UV_PYTHON: that env var overrides uv's interpreter *selection* for every
# uv invocation for the rest of this pipeline, not just Detect's scan of
# this product -- which is exactly what broke update-manual-manifest.py's
# own 3.11-pinned project last time.
UV_PYTHON="$(grep 'requires-python' ${SOURCE_DIR}/pyproject.toml | grep -oE '[0-9]+\.[0-9]+')"
UV_PYTHON="${UV_PYTHON:-3.13}"
"${UV_BIN_PATH}" python install "${UV_PYTHON}"
"${UV_BIN_PATH}" --directory "${SOURCE_DIR}" python pin "${UV_PYTHON}"
