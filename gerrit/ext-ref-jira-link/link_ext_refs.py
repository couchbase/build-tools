#!/usr/bin/env python3

"""
Add a Gerrit change to the "Gerrit Reviews" field of the Jira issues its
commit message names in Ext-ref: trailers.

Couchbase's own Gerrit fills that field in for changes on
review.couchbase.org.  Changes on an outside Gerrit - AsterixDB's, say -
carry the issue in an Ext-ref: trailer instead, and nothing links them
back to Jira.  This does that, in the same shape as the entries the
Gerrit integration writes, so the two sit together in the field.

Intended to run as a Gerrit-triggered Jenkins job.  When triggered by
the Gerrit Trigger plugin everything comes from the environment:

  GERRIT_CHANGE_COMMIT_MESSAGE (base64)   where the Ext-refs are
  GERRIT_CHANGE_SUBJECT                   the link text
  GERRIT_CHANGE_URL                       what we link to
  GERRIT_PROJECT, GERRIT_BRANCH           the repo:/branch: annotation

Any of those can be overridden on the command line, and the message can
be read from a file or stdin instead, which is how to try it out
locally.

Jira credentials come from JIRA_URL, JIRA_USERNAME and JIRA_API_TOKEN,
or from ~/.ssh/cloud-jira-creds.json, as elsewhere in build-tools.
Nothing is written unless --update is given.

Needs nothing but a python3 - no third-party modules - so it runs on
whatever agent the Gerrit trigger happens to pick.

Exit codes: 0 done or nothing to do, 2 the run itself failed.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_FIELD_NAME = "Gerrit Reviews"
DEFAULT_CREDS_FILE = "~/.ssh/cloud-jira-creds.json"
DEFAULT_TIMEOUT = 30

# The Gerrit integration abbreviates the subject to its first few words
# before using it as the link text; matching that keeps the field tidy
DEFAULT_SUBJECT_WORDS = 5

# How many times to re-read and re-apply if someone else writes the
# field between our read and our write
DEFAULT_ATTEMPTS = 3

# The field holds Jira Server wiki markup, one entry per line:
#
#   [subject|https://gerrit/c/project/+/1234]\trepo:project\tbranch:main
#
# possibly with a "(/)" merged marker ahead of the link.  Entries are
# separated either by a newline or by "\\", wiki markup for a forced
# line break; we read both.
#
# We write newlines, because a value separated only by "\\" has been
# seen to come back with just its first entry linked, the rest left as
# literal "[text|url]", while newline-separated values come back with
# every entry linked.  Rewriting such a field with newlines restores the
# links.  The mechanism isn't pinned down - an entry the integration
# later appended behind a "\\" linked fine - so this rests on what has
# been observed rather than on a rule.  --separator is there if that
# needs revisiting.
ENTRY_SEPARATOR = "\n"
ENTRY_SPLIT_RE = re.compile(r"\\\\|\r?\n")
ENTRY_RE = re.compile(r"\[(?P<text>[^\]|]*)\|(?P<url>[^\]|]+)\]")

EXT_REF_RE = re.compile(r"^Ext-ref:[ \t]*(.+)$", re.IGNORECASE | re.MULTILINE)

# "Between 2 and 9 uppercase alphanumerics, a dash, and 1 to 6 digits not
# followed by a dash or a digit" - the trailing bit keeps CVE-2026-12345
# from matching as CVE-2026
ISSUE_KEY_RE = re.compile(r"\b[A-Z][A-Z0-9]{1,8}-[0-9]{1,6}(?![-0-9])\b")

# A Gerrit change URL ends in the change number, with or without a
# trailing slash, whatever the host puts in front of it
CHANGE_URL_RE = re.compile(r"^https?://([^/]+)/.*?([0-9]+)/?$")

# Leading "[NO ISSUE][MISC]"-style tags, as AsterixDB subjects begin with
TAG_PREFIX_RE = re.compile(r"^(?:\s*\[[^\]]*\])+\s*")


class HttpError(Exception):
    """
    A request that didn't come back, or came back something other than
    a 2xx
    """


def http_json(url, params=None, data=None, method=None, auth=None,
              timeout=DEFAULT_TIMEOUT):
    """
    Make a JSON HTTP request and return the body as text

    The stdlib rather than requests, deliberately: this runs on whatever
    Jenkins agent the Gerrit trigger picks, and an agent without
    requests installed would otherwise fail the build on an import.
    """
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"

    body = None
    headers = {"Accept": "application/json"}
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if auth:
        credentials = base64.b64encode(
            ":".join(auth).encode("utf-8")
        ).decode("ascii")
        headers["Authorization"] = f"Basic {credentials}"

    request = urllib.request.Request(
        url, data=body, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace").strip()[:200]
        raise HttpError(f"{exc.code} {exc.reason} for {url}"
                        + (f": {detail}" if detail else "")) from None
    except (urllib.error.URLError, OSError) as exc:
        raise HttpError(f"{url}: {exc}") from None


def read_commit_message(args):
    """
    Return the commit message to read Ext-refs from, from
    --message-file, from the environment the Gerrit Trigger plugin sets
    up, or from the git checkout in --repo, in that order
    """
    if args.message_file:
        if args.message_file == "-":
            return sys.stdin.read()
        with open(args.message_file, encoding="utf-8") as msg_file:
            return msg_file.read()

    encoded = os.environ.get("GERRIT_CHANGE_COMMIT_MESSAGE")
    if encoded:
        # The Gerrit Trigger plugin base64-encodes this one
        return base64.b64decode(encoded).decode("utf-8")

    revision = os.environ.get("GERRIT_PATCHSET_REVISION", "HEAD")
    return subprocess.run(
        ("git", "log", "-1", "--format=%B", revision), cwd=args.repo,
        check=True, text=True, stdout=subprocess.PIPE
    ).stdout


def find_ext_refs(message, projects):
    """
    Return the issue keys named in the message's Ext-ref: trailers, in
    the order they appear and without repeats, keeping only those in
    `projects` if that is non-empty
    """
    keys = []
    for trailer in EXT_REF_RE.findall(message):
        for key in ISSUE_KEY_RE.findall(trailer):
            if projects and key.split("-", 1)[0] not in projects:
                continue
            if key not in keys:
                keys.append(key)
    return keys


def link_text(subject, words, strip_tags=True):
    """
    Return the link text to use for a change with this subject

    Square brackets and pipes end a wiki markup link, so they can't
    survive in the text of one.  An AsterixDB subject leads with
    "[NO ISSUE][MISC]"-style tags, which are dropped whole rather than
    mangled; anything left is replaced, so a stray bracket can't break
    the rest of the field.
    """
    subject = " ".join(subject.split())
    if strip_tags:
        stripped = TAG_PREFIX_RE.sub("", subject)
        # A subject that is nothing but tags keeps them, mangled or not,
        # rather than becoming an empty link
        if stripped:
            subject = stripped
    subject = subject.translate(str.maketrans({"[": "(", "]": ")", "|": "/"}))
    if words > 0:
        subject = " ".join(subject.split(" ")[:words])
    return subject


def gerrit_base(args, url):
    """
    Return the base URL of the Gerrit the change is on
    """
    if args.gerrit_url:
        return args.gerrit_url.rstrip("/")
    match = re.match(r"^(https?://[^/]+)", url or "")
    return match.group(1) if match else None


def change_number(args, url):
    """
    Return the number of the change being linked
    """
    number = args.change or os.environ.get("GERRIT_CHANGE_NUMBER")
    if number:
        return str(number)
    match = CHANGE_URL_RE.match(url or "")
    return match.group(2) if match else None


def previous_message(args, url):
    """
    Return the commit message of the patchset before this one, None if
    there isn't one, and raise if it can't be fetched

    Gerrit hands over every patchset's message in a single call, so this
    is one request whatever the patchset number.  It goes out
    unauthenticated: an outside Gerrit's changes are public, and the
    Jenkins agent has no HTTP credentials for one.
    """
    if args.previous_message_file:
        with open(args.previous_message_file, encoding="utf-8") as handle:
            return handle.read()

    patchset = args.patchset or os.environ.get("GERRIT_PATCHSET_NUMBER")
    if not patchset:
        raise ValueError("no patchset number to work back from")
    patchset = int(patchset)
    if patchset <= 1:
        # Nothing was linked before the first patchset
        return None

    base = gerrit_base(args, url)
    number = change_number(args, url)
    if not (base and number):
        raise ValueError("no Gerrit URL and change number to ask")

    body = http_json(
        f"{base}/changes/{number}",
        params=[("o", "ALL_REVISIONS"), ("o", "ALL_COMMITS")],
        timeout=args.timeout,
    )
    # Gerrit guards its JSON against cross-site script inclusion
    change = json.loads(body.split("\n", 1)[1])

    for revision in change.get("revisions", {}).values():
        if revision.get("_number") == patchset - 1:
            return revision.get("commit", {}).get("message", "")
    raise ValueError(f"change {number} has no patchset {patchset - 1}")


def stale_ext_refs(args, url, current):
    """
    Return the issues the previous patchset named that this one doesn't,
    whose links are therefore stale, and an empty set if that can't be
    worked out

    Only a removal we can actually see is acted on.  If the previous
    patchset is unreachable we leave every link alone rather than guess:
    a link left behind is untidy, one deleted in error is worse.
    """
    if args.no_prune:
        return set()
    try:
        previous = previous_message(args, url)
    except (HttpError, ValueError, OSError, KeyError) as exc:
        print(f"Not checking for removed Ext-refs: {exc}", file=sys.stderr)
        return set()
    if previous is None:
        return set()
    return set(find_ext_refs(previous, set(args.jira_projects))) - set(current)


def change_url(args):
    """
    Return the URL of the change to link to
    """
    url = args.change_url or os.environ.get("GERRIT_CHANGE_URL")
    if url:
        return url.strip()
    if args.gerrit_url and args.project and args.change:
        return (f"{args.gerrit_url.rstrip('/')}/c/{args.project}"
                f"/+/{args.change}")
    sys.exit(
        "Nothing to link to: pass --change-url, or run with "
        "GERRIT_CHANGE_URL set"
    )


def same_change(one, other):
    """
    Returns true if two URLs point at the same Gerrit change

    Gerrit hands out several spellings of a change URL - with and
    without the project in the path, with and without a trailing slash -
    so compare on the host and change number rather than the text.
    """
    if one.rstrip("/") == other.rstrip("/"):
        return True
    one_match = CHANGE_URL_RE.match(one)
    other_match = CHANGE_URL_RE.match(other)
    return (one_match is not None and other_match is not None
            and one_match.groups() == other_match.groups())


def split_entries(value):
    """
    Return the field's entries, one per line, blank lines dropped
    """
    if not value:
        return []
    return [entry for entry in ENTRY_SPLIT_RE.split(value) if entry.strip()]


def format_entry(text, url, suffix):
    return f"[{text}|{url}]{suffix}"


def update_entries(entries, text, url, suffix):
    """
    Add an entry for `url` to `entries` in place, or bring an existing
    one's link text up to date, and return whether anything changed

    A change's subject can move under it while the change is in review,
    and a new patchset re-triggers us, so an entry that's already there
    still wants checking.  Anything ahead of the link - the "(/)" the
    integration marks merged changes with - is left where it is, as is
    the URL already recorded, which saves rewriting the field just
    because Gerrit handed us a different spelling of the same change.
    """
    for index, entry in enumerate(entries):
        match = ENTRY_RE.search(entry)
        if match is None or not same_change(match.group("url"), url):
            continue
        replacement = (entry[:match.start()]
                       + format_entry(text, match.group("url"), suffix))
        if replacement == entry:
            return False
        entries[index] = replacement
        return True
    entries.append(format_entry(text, url, suffix))
    return True


def join_entries(entries, separator=ENTRY_SEPARATOR):
    return separator.join(entries)


def remove_entry(entries, url):
    """
    Drop the entry for `url` from `entries` in place, and return whether
    there was one

    Only an entry for this very change is ever removed; everything else
    in the field, including entries some other job or a person put
    there, is left alone.
    """
    for index, entry in enumerate(entries):
        match = ENTRY_RE.search(entry)
        if match is not None and same_change(match.group("url"), url):
            del entries[index]
            return True
    return False


def find_entry(entries, url):
    """
    Return the entry linking to `url`, or None if there isn't one
    """
    for entry in entries:
        match = ENTRY_RE.search(entry)
        if match is not None and same_change(match.group("url"), url):
            return entry
    return None


class Jira:
    """
    The slice of the Jira Cloud REST API this needs

    v2 rather than v3 because the Gerrit integration stores this field
    as wiki markup, and v2 is the one that hands it over and takes it
    back as text.  Read through v3 it arrives as ADF converted from that
    markup, which is lossy in both directions.
    """

    def __init__(self, url, user, token, timeout=DEFAULT_TIMEOUT):
        self.url = url.rstrip("/")
        self.timeout = timeout
        self.auth = (user, token)

    def _request(self, method, path, api="2", **kwargs):
        return json.loads(http_json(
            f"{self.url}/rest/api/{api}{path}", method=method,
            auth=self.auth, timeout=self.timeout, **kwargs
        ) or "null")

    def field_id(self, name):
        """
        Return the customfield_NNNNN id of the field called `name`
        """
        fields = self._request("GET", "/field")
        matches = [field["id"] for field in fields
                   if field.get("name") == name]
        if not matches:
            sys.exit(f"Jira has no field called {name!r}")
        if len(matches) > 1:
            sys.exit(
                f"Jira has {len(matches)} fields called {name!r} "
                f"({', '.join(matches)}); pass --field-id to pick one"
            )
        return matches[0]

    def get_field(self, key, field_id):
        """
        Return an issue's value for `field_id` as wiki markup text
        """
        issue = self._request(
            "GET", f"/issue/{key}", params={"fields": field_id}
        )
        return issue["fields"].get(field_id) or ""

    def set_field(self, key, field_id, value):
        self._request(
            "PUT", f"/issue/{key}", data={"fields": {field_id: value}}
        )


CREDS_KEYS = ("url", "username", "apitoken")


def read_creds(path, url):
    """
    Return the (url, username, apitoken) in the credentials file at
    `path`, which is the one the rest of build-tools uses:

      {"url": ..., "username": ..., "apitoken": ...}

    A list of those is accepted too, for a file covering more than one
    Jira: the entry whose url matches `url` is taken, or the only entry
    there is if `url` wasn't given.
    """
    try:
        with open(path, encoding="utf-8") as creds_file:
            creds = json.load(creds_file)
    except OSError as exc:
        sys.exit(
            f"No Jira credentials: set JIRA_USERNAME and JIRA_API_TOKEN, "
            f"or provide {path} ({exc})"
        )
    except ValueError as exc:
        sys.exit(f"{path} is not valid JSON: {exc}")

    if isinstance(creds, list):
        usable = [entry for entry in creds if isinstance(entry, dict)
                  and all(entry.get(key) for key in CREDS_KEYS)]
        if url:
            usable = [entry for entry in usable
                      if entry["url"].rstrip("/") == url.rstrip("/")]
        if len(usable) != 1:
            # The keys are safe to name; the values are not
            shapes = ["+".join(sorted(entry)) if isinstance(entry, dict)
                      else type(entry).__name__ for entry in creds]
            sys.exit(
                f"{path} holds {len(creds)} entries and {len(usable)} of "
                f"them are usable Jira credentials"
                + (f" for {url}" if url else "")
                + f"; expected one entry with "
                f"{', '.join(CREDS_KEYS)}, found {'; '.join(shapes)}. "
                f"Pass --jira-url to pick one, or --creds-file to point "
                f"somewhere else"
            )
        creds = usable[0]

    if not isinstance(creds, dict):
        sys.exit(
            f"{path} should hold an object with {', '.join(CREDS_KEYS)}, "
            f"or a list of them, not a {type(creds).__name__}"
        )

    return (url or creds.get("url"), creds.get("username"),
            creds.get("apitoken"))


def connect_jira(args):
    """
    Return a Jira client, authenticated from the environment or from
    --creds-file
    """
    url = args.jira_url or os.environ.get("JIRA_URL")
    user = os.environ.get("JIRA_USERNAME")
    token = os.environ.get("JIRA_API_TOKEN")

    if not (user and token):
        url, user, token = read_creds(
            os.path.expanduser(args.creds_file), url
        )

    missing = [name for name, value
               in (("url", url), ("username", user), ("apitoken", token))
               if not value]
    if missing:
        sys.exit(f"Incomplete Jira credentials: no {', '.join(missing)}")
    return Jira(url, user, token, args.timeout)


def edit_issue(jira, key, field_id, args, apply_edit, settled, done, noop):
    """
    Read one issue's Gerrit Reviews field, apply `apply_edit` to its
    entries and write it back, re-reading and re-applying if the field
    moves under us

    Two changes naming the same issue can land at once, and the field is
    written whole, so a blind read-modify-write can drop the other one's
    entry.  Re-reading until `settled` holds of what we wrote is the
    closest thing to a compare and swap the REST API offers.
    """
    for attempt in range(1, args.attempts + 1):
        entries = split_entries(jira.get_field(key, field_id))
        if not apply_edit(entries):
            print(f"{key}: {noop}")
            return True

        if args.dry_run or not args.update:
            what = "Would set" if args.update else "Would set (needs --update)"
            print(f"{key}: {what} {field_id} to:")
            for entry in entries or ["(empty)"]:
                print(f"    {entry}".replace("\t", " " * 4))
            return True

        jira.set_field(key, field_id,
                       join_entries(entries, args.separator))

        if settled(split_entries(jira.get_field(key, field_id))):
            print(f"{key}: {done}")
            return True
        print(f"{key}: field changed under us, retrying "
              f"({attempt}/{args.attempts})", file=sys.stderr)

    print(f"{key}: gave up after {args.attempts} attempts", file=sys.stderr)
    return False


def link_issue(jira, key, field_id, text, url, suffix, args):
    """
    Add this change to one issue's Gerrit Reviews field
    """
    return edit_issue(
        jira, key, field_id, args,
        lambda entries: update_entries(entries, text, url, suffix),
        lambda entries: find_entry(entries, url) is not None,
        f"added {url}", f"already links to {url}",
    )


def unlink_issue(jira, key, field_id, url, args):
    """
    Take this change back out of an issue's Gerrit Reviews field, for an
    issue an earlier patchset named and this one no longer does
    """
    return edit_issue(
        jira, key, field_id, args,
        lambda entries: remove_entry(entries, url),
        lambda entries: find_entry(entries, url) is None,
        f"removed {url}", f"has no link to {url} to remove",
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Add a Gerrit change to the Gerrit Reviews field of "
                    "the Jira issues its Ext-ref: trailers name",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--update", action="store_true",
        help="Write to Jira (nothing is written without this)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print what would be written to Jira, and write nothing"
    )

    source = parser.add_argument_group("the change being linked")
    source.add_argument(
        "--message-file", metavar="FILE",
        help="Read the commit message from FILE ('-' for stdin) rather "
             "than from the Gerrit environment or the git checkout"
    )
    source.add_argument(
        "--repo", metavar="DIR", default=".",
        help="git checkout to read the commit message from, if it isn't "
             "in the environment"
    )
    source.add_argument(
        "--subject", default=os.environ.get("GERRIT_CHANGE_SUBJECT"),
        help="Change subject, used as the link text (default: "
             "$GERRIT_CHANGE_SUBJECT, or the commit message's first line)"
    )
    source.add_argument(
        "--subject-words", type=int, default=DEFAULT_SUBJECT_WORDS,
        metavar="N",
        help="Words of the subject to use as the link text, as the "
             "Gerrit integration does; 0 for all of it"
    )
    source.add_argument(
        "--keep-tags", action="store_true",
        help="Keep the leading [NO ISSUE][MISC]-style tags of the "
             "subject in the link text, rather than dropping them"
    )
    source.add_argument(
        "--change-url", metavar="URL",
        help="Change to link to (default: $GERRIT_CHANGE_URL, else built "
             "from --gerrit-url, --project and --change)"
    )
    source.add_argument(
        "--gerrit-url", metavar="URL",
        default=os.environ.get("GERRIT_URL"),
        help="Base URL of the Gerrit, for building a change URL"
    )
    source.add_argument(
        "--change", metavar="N",
        default=os.environ.get("GERRIT_CHANGE_NUMBER"),
        help="Change number, for building a change URL"
    )
    source.add_argument(
        "--patchset", metavar="N",
        default=os.environ.get("GERRIT_PATCHSET_NUMBER"),
        help="Patchset number, used to find the one before it"
    )
    source.add_argument(
        "--previous-message-file", metavar="FILE",
        help="Read the previous patchset's commit message from FILE "
             "rather than asking Gerrit for it"
    )
    source.add_argument(
        "--no-prune", action="store_true",
        help="Don't remove links to issues the previous patchset named "
             "and this one doesn't"
    )
    source.add_argument(
        "--project", default=os.environ.get("GERRIT_PROJECT"),
        help="Gerrit project, recorded as repo: in the field"
    )
    source.add_argument(
        "--branch", default=os.environ.get("GERRIT_BRANCH"),
        help="Gerrit branch, recorded as branch: in the field"
    )

    target = parser.add_argument_group("Jira")
    target.add_argument(
        "--jira-project", action="append", metavar="KEY", default=[],
        dest="jira_projects",
        help="Only link issues in this project, eg. MB; repeatable "
             "(default: every issue an Ext-ref: names)"
    )
    target.add_argument(
        "--field-name", default=DEFAULT_FIELD_NAME,
        help="Name of the field to add the link to"
    )
    target.add_argument(
        "--field-id", metavar="ID", default=None,
        help="Id of the field to add the link to, eg. customfield_11243 "
             "(default: looked up from --field-name)"
    )
    target.add_argument(
        "--jira-url", metavar="URL", default=None,
        help="Jira base URL (default: $JIRA_URL, else the credentials "
             "file's url)"
    )
    target.add_argument(
        "--creds-file", metavar="FILE", default=DEFAULT_CREDS_FILE,
        help="Jira credentials, used unless JIRA_USERNAME and "
             "JIRA_API_TOKEN are set"
    )
    target.add_argument(
        "--timeout", type=int, default=DEFAULT_TIMEOUT, metavar="SECONDS",
        help="Timeout for a single Jira request"
    )
    target.add_argument(
        "--attempts", type=int, default=DEFAULT_ATTEMPTS, metavar="N",
        help="Times to re-read and re-apply if the field is written "
             "under us"
    )
    target.add_argument(
        "--separator", choices=["newline", "wiki"], default="newline",
        help="What to separate entries with when writing the field: a "
             "newline, or wiki markup's '\\\\' forced line break, which "
             "the Gerrit integration uses but which costs every entry "
             "after the first its link"
    )
    target.add_argument(
        "--strict", action="store_true",
        help="Fail the build if an issue can't be updated, rather than "
             "warning and carrying on"
    )

    args = parser.parse_args()
    args.separator = "\n" if args.separator == "newline" else "\\\\"
    return args


def main():
    args = parse_args()

    try:
        message = read_commit_message(args)
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        sys.exit(f"Unable to read the commit message: {exc}")

    keys = find_ext_refs(message, set(args.jira_projects))
    url = change_url(args)
    stale = sorted(stale_ext_refs(args, url, keys))

    if not keys and not stale:
        print("No Ext-ref: trailer naming an issue to link; nothing to do")
        return

    subject = args.subject or message.strip().split("\n", 1)[0]
    text = link_text(subject, args.subject_words, not args.keep_tags)
    suffix = ""
    if args.project:
        suffix += f"\trepo:{args.project}"
    if args.branch:
        suffix += f"\tbranch:{args.branch}"

    if keys:
        print(f"Linking {url} to {', '.join(keys)}")
    if stale:
        print(f"Unlinking {url} from {', '.join(stale)}, no longer named "
              f"by an Ext-ref:")

    jira = connect_jira(args)
    try:
        field_id = args.field_id or jira.field_id(args.field_name)
    except HttpError as exc:
        sys.exit(f"Unable to look up the {args.field_name!r} field: {exc}")

    work = ([(key, link_issue, (text, url, suffix, args)) for key in keys]
            + [(key, unlink_issue, (url, args)) for key in stale])
    failed = []
    for key, action, extra in work:
        try:
            if not action(jira, key, field_id, *extra):
                failed.append(key)
        except HttpError as exc:
            print(f"{key}: {exc}", file=sys.stderr)
            failed.append(key)

    if failed and args.strict:
        sys.exit(f"Unable to update {', '.join(failed)}")
    if failed:
        print(f"Carried on past {', '.join(failed)}; "
              f"pass --strict to fail the build instead", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except SystemExit as exit_exc:
        if isinstance(exit_exc.code, str):
            print(exit_exc.code, file=sys.stderr)
            raise SystemExit(2) from None
        raise
