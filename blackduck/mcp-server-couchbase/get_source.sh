#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

SOURCE_DIR=mcp-server-couchbase

# The default Detect jar predates the UV detector (added in 10.5.0), so it
# cannot scan this uv-managed project's pyproject.toml/uv.lock directly --
# its PIP detectors would need a requirements.txt, and a flattened
# "uv export" closure makes every transitive dependency appear as a direct
# dependency in the BOM. Pin 10.7.0, the latest 10.x release (also used by
# couchbase-lite-react-native).
export DETECT_JAR_VERSION=10.7.0

# Prefer the published PyPI sdist so we scan exactly what ships. Build an sdist
# from the git repository if the version required has not been published
python -m pip download --no-deps --no-binary couchbase-mcp-server --no-cache-dir couchbase-mcp-server==$VERSION || true
TARBALL=$(find . -maxdepth 1 -name "couchbase_mcp_server-*.tar.gz")
if [ -z "${TARBALL}" ]; then
    if [ "$RELEASE" == "$VERSION" ] || [ "$RELEASE" == "master" ]; then
        RELEASE="main"
    fi
    echo "Version $VERSION does not exist on PyPI, checking out git repository and building sdist."
    git clone https://github.com/couchbase/mcp-server-couchbase.git $SOURCE_DIR
    pushd $SOURCE_DIR
    TAG="v${VERSION}"
    if git rev-parse --verify --quiet $TAG >& /dev/null
    then
        echo "Tag $TAG exists, checking it out"
        git checkout $TAG
    else
        echo "No tag $TAG, checking out $RELEASE"
        git checkout $RELEASE
    fi
    # Build outside the clone so the output directory doesn't end up
    # inside the sdist itself
    uv build --sdist --out-dir ../bd-sdist
    popd
    mv bd-sdist/*.tar.gz .
    rm -rf $SOURCE_DIR bd-sdist
    TARBALL=$(find . -maxdepth 1 -name "couchbase_mcp_server-*.tar.gz")
fi

tar -xf $TARBALL
TARBALL_CONTENTS_DIR=$(basename $TARBALL .tar.gz)
mkdir $SOURCE_DIR
mv $TARBALL_CONTENTS_DIR/* $SOURCE_DIR
rm -rf $TARBALL_CONTENTS_DIR
rm $TARBALL

pushd $SOURCE_DIR
# Detect's UV detectors scan pyproject.toml + uv.lock directly, but the dev
# tools (ruff, pytest, ...) live in the "dev" extra under
# [project.optional-dependencies], and the preferred UV CLI detectable runs
# "uv tree --no-group dev", which only filters [dependency-groups] -- extras
# pass straight through into the BOM as direct dependencies. (Only the
# fallback UV Lock detectable's parser treats extras as excludable groups,
# and we can't force that path while uv is on the scanner's PATH.) So strip
# the dev extra from the project before the scan; "uv remove" updates
# pyproject.toml and uv.lock coherently while leaving all other locked
# versions untouched, and --no-sync avoids materialising a .venv in the
# scan tree.
# This also ensures pyproject.toml carries an explicit "[tool.uv] managed =
# true": Detect 10.7.0's UV detectables skip the project entirely (empty BOM)
# unless that key is literally present, even though uv itself defaults
# "managed" to true when the key is absent. (Fixed upstream after 10.7.0,
# but even there the [tool.uv] section itself must exist.)
#
# uv supplies the interpreter (3.12 => stdlib tomllib) and the "packaging"
# helper in an ephemeral cached env, so this works regardless of the agent's
# system Python and leaves no trace in the scan tree.
DEV_DEPS=$(uv run --no-project --python 3.12 --with packaging python - <<'PY'
import re
import tomllib
from packaging.requirements import Requirement

with open("pyproject.toml", encoding="utf-8") as fh:
    src = fh.read()
data = tomllib.loads(src)

deps = data.get("project", {}).get("optional-dependencies", {}).get("dev", [])
print(" ".join(Requirement(d).name for d in deps))

if "managed" not in data.get("tool", {}).get("uv", {}):
    match = re.search(r"(?m)^\[tool\.uv\][ \t]*$", src)
    if match:
        src = src[:match.end()] + "\nmanaged = true" + src[match.end():]
    else:
        src += "\n[tool.uv]\nmanaged = true\n"
    tomllib.loads(src)  # fail loudly if the edit broke the TOML
    with open("pyproject.toml", "w", encoding="utf-8") as fh:
        fh.write(src)
PY
)
if [ -n "${DEV_DEPS}" ]; then
    uv remove --no-sync --optional dev ${DEV_DEPS}
fi
popd
