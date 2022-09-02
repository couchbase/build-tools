import pathlib
import re

# Replace top-level "inline" function declarations with "__forceinline"
regex = re.compile(r'^inline')
unistr = pathlib.Path("unistr.h")
with unistr.open("r") as f:
    lines = [ regex.sub("__forceinline", x) for x in f.readlines() ]
with unistr.open("w") as f:
    f.writelines(lines)
