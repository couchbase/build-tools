"""
Re-usable utility functions
"""

import logging
import os
import pathlib
import subprocess
from enum import Enum
from jinja2 import Template
from typing import Dict, List, Union

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

    # If caller requested capture_output, don't muck with stderr/stdout;
    # otherwise, suppress them unless debugging
    if not "capture_output" in kwargs and not global_debug:
        kwargs["stdout"] = subprocess.DEVNULL
        kwargs["stderr"] = subprocess.DEVNULL

    # If caller specified 'check', don't override; otherwise set check=True
    if not "check" in kwargs:
        kwargs["check"] = True

    return subprocess.run(cmd, **kwargs)


def run_output(cmd: Union[List[str], str], **kwargs) -> str:
    """
    Execute a command and return its stdout, with optional echoing
    """

    return run(cmd, **kwargs, capture_output=True).stdout.decode()


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


def sync_to_s3bucket(
    region: str, bucket: str, profile: str, s3_path: str,
    local_dir: pathlib.Path, only_recent: bool
) -> None:
    """
    Synchronizes the *contents* of a local directory to an S3 path as
    efficiently as possible. If "only_recent" is True, will attempt to
    sync only changes from the last 24 hours.
    """

    # Current implementation uses rclone, which requires us to first set
    # up a "remote" with various parameters. We'll save that in a local file.
    # The remote is named "s3remote", and is of type "s3".
    script_dir = pathlib.Path(__file__).resolve().parent
    conf_file = script_dir / "rclone.conf"
    run(
        f"rclone --quiet --config {conf_file} config create s3remote s3 "
        f"env_auth true acl public-read region {region} provider AWS "
        f"no_check_bucket true"
    )

    # Only way to specify the AWS credentials profile to use :(
    os.environ["AWS_PROFILE"] = profile

    # If doing a "top-up" recents-only sync, we want different options
    # than if doing a full sync
    if only_recent:
        opt_flags = "--no-traverse --max-age 24h"
    else:
        opt_flags = "--fast-list"

    # Do the sync, with all the options for best efficiency. Note the
    # destination path names the "s3remote" we set up earlier. Also note
    # that we use "rclone copy" rather than "rclone sync" - the main
    # difference is that "sync" would delete files on S3 that have been
    # deleted locally. However, due to Cloudfront caching, customers can
    # get into a bad state if we delete old yum/apt metadata files -
    # they may get a cached copy of, say, repomd.xml which tells them to
    # download an older version of a secondary metadata file, and if
    # that file is already deleted from S3 (and didn't happen to be
    # cached by Cloudfront) they'll get errors. There's as much as a
    # 12-hour window where Cloudfront may serve an inconsistent view of
    # the repository after we upload changes. In general, only
    # repository metadata files should ever get deleted from the local
    # repositories, and they're quite small, so there isn't much of a
    # downside to leaving all of them on S3. Maybe every so often we
    # could do a full "sync" just to clean them out.
    try:
        run(
            f"rclone --config {conf_file} copy --progress -v --skip-links "
            f"--update --use-server-modtime {opt_flags} "
            f"{local_dir} s3remote:{bucket}/{s3_path}"
        )
    finally:
        conf_file.unlink()

class Action(Enum):
    ADD = 1
    REMOVE = 2
