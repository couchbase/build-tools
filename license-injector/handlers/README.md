The handlers in this directory contain json objects which describe inline/block comment options alongside the files they apply to. The schema looks like this:

{
    "block": {
        "open": block comment opener,
        "close": block comment closer
    },
    "inline": array of inline comment prefixes,
    "extensions": array of file extensions this handler applies to,
    "names": specific directory/file regex patterns to which this handler applies,
    "after": an array of regex patterns indicating lines which should come before the comment,
    "shebangs": array of possible shebangs,
    "add_always": whether files identified by this handler should always receive a header (default: true)
}

All of these settings are optional.