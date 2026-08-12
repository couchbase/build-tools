#!/usr/bin/env python3

"""
Tests for link_ext_refs.py, covering everything up to the point it talks
to Jira.  No network, no credentials: run it with ./test_link_ext_refs.py

The fixtures are real - MESSAGE is AsterixDB change 21540's commit
message, LIVE is what MB-73268's Gerrit Reviews field actually held -
because the two things most worth pinning down are that we read the
field's wiki markup exactly as the Gerrit integration writes it, and
that a subject full of square brackets can't corrupt it.
"""

import json
import sys

from link_ext_refs import (
    find_ext_refs, join_entries, link_text, remove_entry, same_change,
    split_entries, update_entries,
)

MESSAGE = """\
[NO ISSUE][MISC] Update Dependencies to address CVEs

 - org.msgpack:msgpack-core: 0.9.11 -> 0.9.12

Ext-ref: MB-73268
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Change-Id: I5fd91dea980b02fc478787a6175a63d09534ac90
"""

SUBJECT = MESSAGE.split("\n", 1)[0]

CBAS = "\trepo:cbas-core\tbranch:trinity"
LIVE = "\\\\".join([
    "[MB-73268: build core-io 1.x's shaded"
    "|https://review.couchbase.org/c/cbas-core/+/250688]" + CBAS,
    "[MB-73268: Update Dependencies to address"
    "|https://review.couchbase.org/c/cbas-core/+/250632]" + CBAS,
    "[MB-73268: substitute compat jars for"
    "|https://review.couchbase.org/c/cbas-core/+/250635]" + CBAS,
    "[MB-73268: dedupe pre-existing compat duplicates"
    "|https://review.couchbase.org/c/cbas-core/+/250682]" + CBAS,
])

URL = "https://asterix-gerrit.ics.uci.edu/c/asterixdb/+/21540"
SUFFIX = "\trepo:asterixdb\tbranch:trinity"

FAILURES = []


def check(label, got, want):
    if got == want:
        print(f"  ok   {label}")
        return
    FAILURES.append(label)
    print(f"  FAIL {label}")
    print(f"         got: {json.dumps(got)}")
    print(f"        want: {json.dumps(want)}")


def test_ext_refs():
    check("the change's own Ext-ref", find_ext_refs(MESSAGE, set()),
          ["MB-73268"])
    check("held to one project", find_ext_refs(MESSAGE, {"MB"}), ["MB-73268"])
    check("held to a project it isn't in", find_ext_refs(MESSAGE, {"CBD"}), [])
    check("several refs, deduped, in order",
          find_ext_refs("Ext-ref: MB-2, MB-1\nExt-ref: MB-1 CBD-9\n", set()),
          ["MB-2", "MB-1", "CBD-9"])
    check("a CVE is not an issue key",
          find_ext_refs("Ext-ref: MB-1 CVE-2026-59902\n", set()), ["MB-1"])
    check("other trailers are not Ext-refs",
          find_ext_refs("Change-Id: I5fd9\nReviewed-on: MB-1\n", set()), [])


def test_link_text():
    check("AsterixDB tags dropped, first five words kept",
          link_text(SUBJECT, 5), "Update Dependencies to address CVEs")
    check("tags kept on request, but made bracket-safe",
          link_text(SUBJECT, 5, strip_tags=False),
          "(NO ISSUE)(MISC) Update Dependencies to")
    check("a pipe in the subject cannot end the link",
          link_text("fix a|b handling", 5), "fix a/b handling")
    check("a subject that is nothing but tags keeps them",
          link_text("[NO ISSUE]", 5), "(NO ISSUE)")
    check("a Couchbase subject is left alone",
          link_text("MB-73268: build core-io 1.x's shaded jars", 5),
          "MB-73268: build core-io 1.x's shaded")
    check("zero words means the whole subject",
          link_text(SUBJECT, 0), "Update Dependencies to address CVEs")


def test_same_change():
    check("trailing slash", same_change(URL, URL + "/"), True)
    check("bare change number",
          same_change(URL, "https://asterix-gerrit.ics.uci.edu/21540"), True)
    check("old #/ style",
          same_change(URL, "https://asterix-gerrit.ics.uci.edu"
                           "/#/c/asterixdb/+/21540/"), True)
    check("a different change",
          same_change(URL, "https://asterix-gerrit.ics.uci.edu"
                           "/c/asterixdb/+/21541"), False)
    check("the same number on another host",
          same_change(URL, "https://review.couchbase.org"
                           "/c/cbas-core/+/21540"), False)


def test_round_trip():
    entries = split_entries(LIVE)
    check("the live field parses into four entries", len(entries), 4)
    check("and rejoins byte for byte in the format it came in",
          join_entries(entries, "\\\\"), LIVE)
    check("an empty field", split_entries(""), [])
    check("an unset field", split_entries(None), [])


def test_separator():
    """
    We write newlines, because a value separated only by "\\\\" has been
    seen to come back with just its first entry linked
    """
    entries = split_entries(LIVE)
    check("writing back uses newlines by default",
          join_entries(entries).count("\n"), 3)
    check("and no forced line breaks survive",
          "\\\\" in join_entries(entries), False)
    check("the old format is still reachable",
          join_entries(entries, "\\\\"), LIVE)
    check("either way it is the same entries",
          split_entries(join_entries(entries)),
          split_entries(join_entries(entries, "\\\\")))


def test_update():
    entries = split_entries(LIVE)
    text = link_text(SUBJECT, 5)
    wanted = f"[{text}|{URL}]{SUFFIX}"

    check("appends", update_entries(entries, text, URL, SUFFIX), True)
    check("the entry it appended", entries[-1], wanted)
    check("the entries already there are untouched",
          join_entries(entries[:4], "\\\\"), LIVE)

    check("re-running changes nothing",
          update_entries(entries, text, URL, SUFFIX), False)
    for spelling in (URL + "/", "https://asterix-gerrit.ics.uci.edu/21540"):
        check(f"nor does {spelling}",
              update_entries(entries, text, spelling, SUFFIX), False)
    check("so the field still has five entries", len(entries), 5)

    check("a subject that moved is updated in place",
          update_entries(entries, "Bump deps for CVEs", URL, SUFFIX), True)
    check("in place, not appended", len(entries), 5)
    check("with the new text",
          entries[-1], f"[Bump deps for CVEs|{URL}]{SUFFIX}")

    empty = []
    update_entries(empty, text, URL, SUFFIX)
    check("the first entry into an empty field", join_entries(empty), wanted)


def test_remove():
    entries = split_entries(LIVE)
    text = link_text(SUBJECT, 5)
    update_entries(entries, text, URL, SUFFIX)

    check("removes the entry for this change",
          remove_entry(entries, URL), True)
    check("and leaves the field as it was found",
          join_entries(entries, "\\\\"), LIVE)
    check("removing again finds nothing", remove_entry(entries, URL), False)
    check("a URL spelled differently still matches",
          (update_entries(entries, text, URL, SUFFIX),
           remove_entry(entries, URL + "/")),
          (True, True))
    check("the field is intact after that too",
          join_entries(entries, "\\\\"), LIVE)

    check("another change's entry is never touched",
          remove_entry(entries, "https://asterix-gerrit.ics.uci.edu"
                                "/c/asterixdb/+/21541"), False)
    check("nor is a Couchbase entry with the same number",
          remove_entry(entries, "https://asterix-gerrit.ics.uci.edu"
                                "/c/asterixdb/+/250688"), False)
    check("so all four are still there", len(entries), 4)

    check("removing from an empty field", remove_entry([], URL), False)


def test_stale():
    """
    What a patchset dropped is the difference between the two messages
    """
    was = "Ext-ref: MB-1\nExt-ref: MB-2\n"
    now = "Ext-ref: MB-2\n"
    check("an Ext-ref that went away",
          set(find_ext_refs(was, set())) - set(find_ext_refs(now, set())),
          {"MB-1"})
    check("nothing dropped when they match",
          set(find_ext_refs(was, set())) - set(find_ext_refs(was, set())),
          set())
    check("a key corrected on a new patchset",
          set(find_ext_refs("Ext-ref: MB-7326\n", set()))
          - set(find_ext_refs("Ext-ref: MB-73268\n", set())),
          {"MB-7326"})
    check("every ref removed at once",
          set(find_ext_refs(was, set()))
          - set(find_ext_refs("no refs", set())),
          {"MB-1", "MB-2"})


def test_legacy():
    """
    Values written before the field moved to Jira Cloud use newlines
    rather than "\\\\", and mark merged changes with "(/)"
    """
    url = "https://review.couchbase.org/c/cbas-core/+/250066"
    entries = split_entries(
        f"(/) [MB-73147: Update Dependencies to address|{url}]{CBAS}\n"
        f"[MB-73147: Supply substituted jars on"
        f"|https://review.couchbase.org/c/cbas-core/+/250127]{CBAS}"
    )
    check("newline-separated values parse", len(entries), 2)
    check("a marked entry that hasn't moved is a no-op",
          update_entries(
              entries, "MB-73147: Update Dependencies to address", url, CBAS
          ), False)
    check("and one that has keeps its marker",
          (update_entries(entries, "MB-73147: Bump deps", url, CBAS),
           entries[0]),
          (True, f"(/) [MB-73147: Bump deps|{url}]{CBAS}"))
    check("a legacy value's entries survive a rewrite",
          split_entries(join_entries(entries)), entries)


def main():
    for test in (test_ext_refs, test_link_text, test_same_change,
                 test_round_trip, test_separator, test_update, test_remove,
                 test_stale, test_legacy):
        print(f"\n{test.__name__}")
        test()

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s): {', '.join(FAILURES)}")
        return 1
    print("\nall pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
