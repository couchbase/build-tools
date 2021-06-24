This tool can be used to mass add/change license text across source files.

Call with `target_license=[license file] node app.js [repo_dir] [--action modify,inject,all(default)] [--optionalhandlers markdown]`

`--action` and `--optionalhandlers` are optional arguments:

- action dictates whether we modify existing headers, inject new or both.
- optionalHandlers accepts a comma-separated list of handler names, any provided handler names which have `enabled=false` will be treated as if `enabled=true`

If an existing copyright notice (+/- license pattern) is found in any non-binary file which is matched by one of the handlers, it is replaced with the target license. If no copyright notice is found in a non-binary file which is explicitly matched by a handler, one is injected.

We do not inject a header if the file does not match any handler, is specifically excluded, or contains a license snippet with no copyright associated.
