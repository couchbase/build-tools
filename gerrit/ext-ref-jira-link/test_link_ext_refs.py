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

import argparse
import json
import sys

from link_ext_refs import (
    drop_aliases, find_entry, find_ext_refs, is_merged, join_entries,
    link_issue, link_text, remove_entry, same_change, split_entries,
    update_entries,
)

MESSAGE = """\
[NO ISSUE][MISC] Update Dependencies to address CVEs

 - org.msgpack:msgpack-core: 0.9.11 -> 0.9.12

Ext-ref: MB-73268
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Change-Id: I5fd91dea980b02fc478787a6175a63d09534ac90
"""

SUBJECT = MESSAGE.split("\n", 1)[0]

# AsterixDB change 21858's subject, the case that made us keep the tags:
# the issue key is in there and nowhere else
TAGGED = "[ASTERIXDB-3878][HYR][MISC] Replace @AiProvenance with terse markers"

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
    check("tags kept, transliterated, and not counted against the words",
          link_text(TAGGED, 5),
          "(ASTERIXDB-3878)(HYR)(MISC) "
          "Replace @AiProvenance with terse markers")
    check("tags kept on the fixture's subject too",
          link_text(SUBJECT, 5),
          "(NO ISSUE)(MISC) Update Dependencies to address CVEs")
    check("tags dropped on request",
          link_text(SUBJECT, 5, keep_tags=False),
          "Update Dependencies to address CVEs")
    check("a pipe in the subject cannot end the link",
          link_text("fix a|b handling", 5), "fix a/b handling")
    check("nor can a backslash, which pairs up into a line break",
          link_text("fix a\\b handling", 5), "fix a/b handling")
    check("a subject that is nothing but tags keeps them as its text",
          link_text("[NO ISSUE]", 5), "(NO ISSUE)")
    check("and still does with tags dropped",
          link_text("[NO ISSUE]", 5, keep_tags=False), "(NO ISSUE)")
    check("a Couchbase subject is left alone",
          link_text("MB-73268: build core-io 1.x's shaded jars", 5),
          "MB-73268: build core-io 1.x's shaded")
    check("zero words means the whole subject",
          link_text(TAGGED, 0),
          "(ASTERIXDB-3878)(HYR)(MISC) "
          "Replace @AiProvenance with terse markers")
    check("a bracket later in the subject goes the same way",
          link_text("fix [x] handling", 5, keep_tags=False),
          "fix (x) handling")


def test_tagged_entries():
    """
    An entry whose text carries transliterated tags has to parse, match
    and rewrite like any other, or we append a second entry for a change
    we already linked
    """
    text = link_text(TAGGED, 5)
    entries = [f"[{text}|{URL}]{SUFFIX}"]
    check("a tagged entry survives a round trip",
          split_entries(join_entries(entries)), entries)
    check("and is found by its URL", find_entry(entries, URL), entries[0])
    check("re-running changes nothing",
          update_entries(entries, text, URL, SUFFIX), False)
    check("so it is not appended twice", len(entries), 1)
    check("a moved subject is still rewritten in place",
          (update_entries(entries, link_text(TAGGED, 3), URL, SUFFIX),
           len(entries)),
          (True, 1))
    check("with the new text",
          entries[0],
          f"[{link_text(TAGGED, 3)}|{URL}]{SUFFIX}")
    check("and it can still be removed", remove_entry(entries, URL), True)
    check("leaving nothing behind", entries, [])


class FakeJira:
    """
    Issue keys mapped to ids, as Jira resolves them: a moved issue
    answers to its old key and its new one with the same id
    """

    def __init__(self, ids):
        self.ids = ids

    def issue_id(self, key):
        return self.ids.get(key)


def test_drop_aliases():
    moved = FakeJira({"CBD-6889": "545950", "MB-74113": "545950"})
    check("an old key for the issue we're linking is not unlinked",
          drop_aliases(moved, ["MB-74113"], ["CBD-6889"]), [])

    two = FakeJira({"MB-1": "1", "MB-2": "2"})
    check("a genuinely dropped Ext-ref still is",
          drop_aliases(two, ["MB-1"], ["MB-2"]), ["MB-2"])
    check("nothing to link means nothing is spared",
          drop_aliases(two, [], ["MB-2"]), ["MB-2"])
    check("a key that names no issue has no link to remove",
          drop_aliases(FakeJira({"MB-1": "1"}), ["MB-1"], ["MB-9"]), [])
    check("even with nothing being linked",
          drop_aliases(FakeJira({}), [], ["MB-9"]), [])
    check("and doesn't take a real removal with it",
          drop_aliases(two, ["MB-1"], ["MB-9", "MB-2"]), ["MB-2"])
    check("one of several stale keys can be an alias",
          drop_aliases(
              FakeJira({"MB-1": "1", "CBD-1": "1", "MB-2": "2"}),
              ["MB-1"], ["CBD-1", "MB-2"]),
          ["MB-2"])


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


def test_merged():
    """
    A change-merged event marks the entry with "(/) ", the way the Gerrit
    integration marks its own, as on MB-75130:

      [subj|asterix-gerrit/22232]...\\\\(/) [MB-75130: ...|review/...]...
    """
    text = link_text(SUBJECT, 5)
    plain = f"[{text}|{URL}]{SUFFIX}"
    marked = f"(/) {plain}"

    entries = split_entries(LIVE)
    update_entries(entries, text, URL, SUFFIX)
    check("not merged yet", is_merged(entries[-1]), False)
    check("change-merged marks the existing entry",
          update_entries(entries, text, URL, SUFFIX, merged=True), True)
    check("with the integration's prefix", entries[-1], marked)
    check("in place, not appended", len(entries), 5)
    check("and now reads as merged", is_merged(entries[-1]), True)
    check("the other entries are untouched",
          join_entries(entries[:4], "\\\\"), LIVE)

    check("a second change-merged changes nothing",
          update_entries(entries, text, URL, SUFFIX, merged=True), False)
    check("nor does a URL spelled differently",
          update_entries(entries, text, URL + "/", SUFFIX, merged=True),
          False)
    check("a late patchset-created keeps the marker",
          (update_entries(entries, text, URL, SUFFIX), entries[-1]),
          (False, marked))
    check("as does one with a new subject",
          (update_entries(entries, "Bump deps", URL, SUFFIX), entries[-1]),
          (True, f"(/) [Bump deps|{URL}]{SUFFIX}"))
    check("still one entry for it", len(entries), 5)

    entries = split_entries(LIVE)
    check("a missing entry is written already marked",
          (update_entries(entries, text, URL, SUFFIX, merged=True),
           entries[-1]),
          (True, marked))
    check("and only once",
          update_entries(entries, text, URL, SUFFIX, merged=True), False)

    entries = [f"(x) {plain}"]
    update_entries(entries, text, URL, SUFFIX, merged=True)
    check("another marker ahead of it stays, behind the merged one",
          entries, [f"(/) (x) {plain}"])

    entries = [f"(/){plain}"]
    check("a marker without the space is still a marker",
          (update_entries(entries, text, URL, SUFFIX, merged=True),
           is_merged(entries[0])),
          (False, True))

    check("an entry with no link is not merged", is_merged("(/) text"), False)
    check("nor is a link with (/) after it",
          is_merged(f"{plain} (/)"), False)


class RacingJira:
    """
    A Jira whose field has a second writer: one that read the field
    before our first write, and writes that stale copy back straight
    after we have checked ours took - the order two change-merged runs
    for a stack sharing one issue fall into
    """

    def __init__(self, value, stale_writes):
        self.value = value
        self.stale = value
        self.stale_writes = stale_writes
        self.reads = self.writes = 0

    def get_field(self, key, field_id):
        self.reads += 1
        value = self.value
        if self.reads % 3 == 2 and self.stale_writes:
            # The read that verifies our write; the other run's lands
            # behind it
            self.stale_writes -= 1
            self.value = self.stale
        return value

    def set_field(self, key, field_id, value):
        self.writes += 1
        self.value = value


def test_merged_race():
    """
    A marker overwritten after our own check is put back, which matters
    because nothing triggers us again once a change has merged
    """
    text = link_text(SUBJECT, 5)
    plain = f"[{text}|{URL}]{SUFFIX}"
    start = f"{LIVE}\n{plain}"

    def run(stale_writes, recheck, attempts=3):
        jira = RacingJira(start, stale_writes)
        args = argparse.Namespace(
            attempts=attempts, dry_run=False, update=True, separator="\n",
            merged=True, merged_recheck=recheck,
        )
        result = link_issue(jira, "MB-73268", "customfield_11243", text,
                            URL, SUFFIX, args)
        return (result, is_merged(split_entries(jira.value)[-1]),
                jira.writes)

    check("unraced, the marker goes on in one write",
          run(0, 0.001), (True, True, 1))
    check("overwritten behind our check, it is written again",
          run(1, 0.001), (True, True, 2))
    check("without the second look the loss goes unnoticed",
          run(1, 0), (True, False, 1))
    check("and a marker that never sticks is reported as a failure",
          run(9, 0.001, attempts=2), (False, False, 2))


def main():
    for test in (test_ext_refs, test_link_text, test_tagged_entries,
                 test_drop_aliases, test_same_change, test_round_trip,
                 test_separator, test_update, test_remove, test_stale,
                 test_legacy, test_merged, test_merged_race):
        print(f"\n{test.__name__}")
        test()

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s): {', '.join(FAILURES)}")
        return 1
    print("\nall pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
