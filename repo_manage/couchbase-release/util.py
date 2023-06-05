"""
Re-usable utility functions
"""

import contextlib
import logging
import os
import pathlib
import subprocess
from jinja2 import Template
from typing import Dict, Iterator, List, Union

# Global debug flag for run()
global_debug: bool = False

def run(cmd: Union[List[str], str], **kwargs) -> subprocess.CompletedProcess:
    """
    Echo command being executed - helpful for debugging
    """

    global global_debug

    # For convenience, if cmd is a str, split on whitespace.
    # Caveat emptor!
    if type(cmd) == str:
        cmd = cmd.split()

    # Always print the command when debugging
    if global_debug:
        print("++", *[
            f"'{x}'" if ' ' in str(x) else x for x in cmd
        ])

    return subprocess.run(cmd, **kwargs, check=True)


def run_output(cmd: Union[List[str], str], **kwargs) -> str:
    """
    Execute a command and return its stdout, with optional echoing
    """

    return run(cmd, **kwargs, capture_output=True).stdout.decode()


@contextlib.contextmanager
def pushd(new_dir: pathlib.Path) -> Iterator:
    """
    Context manager for handling a given set of code/commands
    being run from a given directory on the filesystem
    """

    old_dir = os.getcwd()
    os.chdir(new_dir)
    logging.debug(f"++ pushd {os.getcwd()}")

    try:
        yield
    finally:
        os.chdir(old_dir)
        logging.debug(f"++ popd (pwd now: {os.getcwd()})")


def enable_run_trace(enable: bool) -> None:
    """
    Enable command tracing from run() and run_output()
    """

    global global_debug
    global_debug = enable


def render_template(
    template_file: pathlib.Path, output_file: pathlib.Path,
    context: Dict
) -> None:
    """
    Render a Jinja2 template file with the specified context to an output file
    """

    logging.debug(f"Generating {output_file}")
    with template_file.open() as t:
        template = Template(t.read(), keep_trailing_newline=True)
    output: str = template.render(context)
    with output_file.open("w") as o:
        o.write(output)
