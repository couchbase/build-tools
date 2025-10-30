# Python Tool Wrapper Scripts

This directory contains generic wrapper scripts for Python-based CLI tools
deployed using `uv`. While these tools can be installed via `uv` on an agent,
many CI jobs download the executable directly from a central location rather
than expecting it on `$PATH`.

To support this use case, this directory contains a shell script template (for
Linux and MacOS) and a Go program template (for Windows) that can be built for
any tool name and downloaded and run directly.

These wrappers are currently used for:
- `patch_via_gerrit`
- `cbdep`

## How It Works

The tool name is templated into both wrapper implementations at build time (by
replacing the `__TOOL_NAME__` placeholder). This ensures the wrapper always
installs the correct tool, regardless of the filename it's downloaded as.

Both implementations follow the same general algorithm:

    add `$HOME/.local/bin` to PATH
    if `$HOME/.local/shims/<tool>` does not exist:
        if `$HOME/.local/bin/uv` does not exist:
            install uv using downloaded installation script
        run `uv tool install <tool>`
    elif `$HOME/.local/shims/<tool>` is more than a couple days old:
        run `uv tool install --reinstall <tool>`
    run `$HOME/.local/shims/<tool>` passing through all arguments

This ensures the wrapper automatically picks up new released versions
of the tool.

## Installing uv

The `uv` binary is a single file with no dependencies. Rather than downloading
it directly, these wrappers use the official `curl | sh` installer script,
which automatically handles platform detection, architecture selection, and
version management.

The installer places `uv` into `$HOME/.local/bin` on all platforms (or
`%USERPROFILE%\.local\bin` on Windows). The `uv tool install` command
creates the tool shim in `$HOME/.local/shims` (or `%USERPROFILE%\.local\shims`
on Windows), as controlled by the `UV_TOOL_BIN_DIR` environment variable.

## Windows

On Linux/Mac, the above logic is implemented as a shell script. On Windows,
a Go program is used instead to produce a native `.exe` file.

The Windows implementation handles several platform-specific considerations:

- The download must be named `<tool>.exe` and be a native executable,
  ruling out `.bat` or `.ps1` scripts
- The `<tool>.exe` created by `uv` in `%USERPROFILE%\.local\shims` is
  not modified by `uv tool install --reinstall`, so the wrapper deletes it
  before reinstalling when an update is needed
- The recommended Powershell installer for `uv` fails with SSL errors on some
  Windows systems. The Go program works around this by explicitly enabling
  TLS1.2 when invoking `powershell`

## Building and Publishing Wrapper Scripts

`build-wrappers.sh` builds the wrapper script and executable for a given tool.
By default, it builds locally for testing. Use the `--publish` flag to upload
to S3 and invalidate the CloudFront cache.

Usage:

```bash
./build-wrappers.sh [--publish] <tool-name>
```

Examples:

```bash
# Build locally for testing (output goes to build/ directory)
./build-wrappers.sh patch_via_gerrit
./build-wrappers.sh cbdep

# Build and publish to S3
./build-wrappers.sh --publish patch_via_gerrit
./build-wrappers.sh --publish cbdep
```

Built files are placed in the `build/` directory, which is gitignored.

Ideally, publishing should only need to be run once per tool, as these same
wrappers should work indefinitely. However, the script can be re-run if updates
are needed.

## Templating

Both wrapper templates in `templates/` contain the placeholder `__TOOL_NAME__`
which is replaced with the actual tool name at build time:

- For the Unix wrapper, `build-wrappers.sh` uses `sed` to replace the
  placeholder and generates the wrapper script
- For the Windows wrapper, `build-wrappers.sh` uses `sed` to create a
  temporary `.go` file, builds it with Go cross-compilation, then deletes
  the temporary file

## Adding a New Tool

To add wrapper support for a new Python tool:

1. Ensure the tool is published to PyPI and installable via `uv tool install`
2. Build and test locally first:
   ```bash
   ./build-wrappers.sh <tool-name>
   # Test the wrappers in build/<tool-name> and build/<tool-name>-windows.exe
   ```
3. When ready, publish the wrappers:
   ```bash
   ./build-wrappers.sh --publish <tool-name>
   ```
4. The wrappers will be available at:
   - Unix: `https://packages.couchbase.com/<tool-name>/<tool-name>-<platform>`
   - Windows: `https://packages.couchbase.com/<tool-name>/<tool-name>.exe`
