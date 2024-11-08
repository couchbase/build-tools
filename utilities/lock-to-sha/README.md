Utility to create a locked manifest from an input manifest and a build
manifest (sha-src).

This is set up to run as a UV (https://github.com/astral-sh/uv) project,
so you can simply cd into this directory and type

    uv run lock-to-sha

and it will ensure the correct version of Python and all dependencies
are downloaded and used.
