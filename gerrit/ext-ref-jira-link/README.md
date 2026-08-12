# Ext-ref Jira link

Adds a Gerrit change to the **Gerrit Reviews** field of the Jira issues
its commit message names in `Ext-ref:` trailers. Meant to run as a
Gerrit-triggered Jenkins job.

Couchbase's own Gerrit fills that field in for changes on
review.couchbase.org. A change on an outside Gerrit - AsterixDB's, say -
names the issue in an `Ext-ref:` trailer instead, and nothing links it
back to Jira. This closes that gap, writing entries in the same shape as
the Gerrit integration's, so the two sit together in one field.

## The field

It holds Jira Server wiki markup, one entry per line:

```
[MB-73268: Update Dependencies to address|https://review.couchbase.org/c/cbas-core/+/250632]<TAB>repo:cbas-core<TAB>branch:trinity
```

That is worth knowing for two reasons. Read through REST v3 the field
arrives as ADF converted from that markup, which is lossy both ways -
so this talks to **v2**, which hands the text over and takes it back
unchanged. And square brackets and pipes end a wiki link, which matters
because AsterixDB subjects begin `[NO ISSUE][MISC]`. Those leading tags
are dropped (`--keep-tags` to keep them), and any bracket or pipe left
in the subject is replaced, so a subject can't corrupt the rest of the
field.

The link text is the first few words of the subject (`--subject-words`,
5 to match the Gerrit integration), and the `repo:` and `branch:`
annotations come from the trigger, giving:

```
[Update Dependencies to address CVEs|https://asterix-gerrit.ics.uci.edu/c/asterixdb/+/21540]<TAB>repo:asterixdb<TAB>branch:trinity
```

### Entries are separated by newlines

Entries arrive separated either by a newline or by `\\`, wiki markup for
a forced line break; both are read, and newlines are written.

That is the one place this doesn't simply match what the integration
does, and it is worth saying plainly that the choice rests on
observation rather than on a mechanism anyone has pinned down:

- MB-73268 held four `\\`-separated entries and only the first rendered
  as a link; the other three showed as literal `[text|url]`.
- MB-73147, whose entries are newline-separated, has six and all six
  are links.
- After this job rewrote MB-73268 with newlines, all of its entries
  became links - and stayed links when the integration appended a
  seventh behind a `\\`.

That last point rules out the obvious explanation, that the `\\`
escapes the `[` after it, because the appended entry sits behind one and
renders fine. Something about the all-on-one-line value was the
problem, and a fresh write cleared it. Newlines are what has been seen
to work, so newlines are what is written; `--separator wiki` is there
if that ever needs revisiting.

## What it does

Every `Ext-ref:` trailer is read, and every issue key in one is linked;
`--jira-project MB` will hold it to one project if a change references
issues elsewhere too.

Re-running is safe, which matters because every new patchset re-triggers
the job. A change already in the field isn't added twice - entries are
matched on the change URL, and on the host and change number if the URL
is spelled differently - and if the subject moved under it, the existing
entry's link text is brought up to date in place.

Entries it doesn't recognise are left alone, text and URL both,
including the `(/)` merged markers the integration puts ahead of a link.
Only the separators between them are rewritten, for the reason above.

An entry someone added by hand for the same change is recognised rather
than duplicated - several MB issues carry AsterixDB links pasted in as
a bare URL, and those get the subject as their link text on the first
run that touches them.

## Removing links

An `Ext-ref:` can go away: corrected on the next patchset, or dropped
because the change turned out not to be about that issue. The link
would otherwise stay on an issue nothing points at any more.

So on each run the previous patchset's commit message is fetched and
its `Ext-ref:` trailers compared with this one's. Any issue the
previous patchset named and this one doesn't has this change's entry
removed - and only this change's entry. Nothing else in the field is
touched, whoever put it there.

Deliberately, this only ever acts on a removal it can see:

- It compares **consecutive** patchsets. A trailer dropped while the
  job wasn't running is never noticed, and that link stays. Widening
  that would mean asking Jira which issues link to the change, which
  also finds links this job never made - including ones added by hand.
  Leaving a stale link is the better failure.
- If the previous patchset can't be fetched, it says so and removes
  nothing. A link left behind is untidy; one deleted in error is worse.
- On patchset 1 there is nothing to compare, so nothing is removed.

`--no-prune` turns it off. `--previous-message-file` supplies the
previous message directly, which is how to try it out locally.

This is the one part that talks to Gerrit, over its REST API,
unauthenticated - an outside Gerrit's changes are public and the agent
has no HTTP credentials for one. Note that `gerrit query` over ssh is
*not* an alternative: it returns only the current patchset's commit
message, not the previous one's.

## Running it

Needs a `python3` and nothing else. No third-party modules, so it runs
on whatever agent the Gerrit trigger picks without anything having to
be installed there first - which is worth keeping that way.

Nothing is written without `--update`, and `--dry-run` prints the field
it would write instead of writing it. To see what a change would do:

```bash
git log --format=%B -1 HEAD | ./link_ext_refs.py --message-file - \
    --change-url https://asterix-gerrit.ics.uci.edu/c/asterixdb/+/21540 \
    --project asterixdb --branch trinity
```

The commit message comes from `--message-file`, or from
`GERRIT_CHANGE_COMMIT_MESSAGE` as the Gerrit Trigger plugin sets it, or
failing both from `git log` in `--repo`. The change to link to comes
from `GERRIT_CHANGE_URL`, or `--change-url`, or is built from
`--gerrit-url`, `--project` and `--change`. Which patchset this is
comes from `GERRIT_PATCHSET_NUMBER` or `--patchset`, and is only needed
to find the one before it.

Exit codes are 0 for success or nothing to do, and 2 if the run itself
failed. An issue that can't be updated - deleted, renamed, or not
visible to the account - is a warning; `--strict` makes it fail the
build.

The tests need no network or credentials:

```bash
./test_link_ext_refs.py
```

### Jira credentials

From `JIRA_URL`, `JIRA_USERNAME` and `JIRA_API_TOKEN`, or failing those
from `~/.ssh/cloud-jira-creds.json` (`--creds-file`), which is the file
the rest of build-tools uses:

```json
{"url": "...", "username": "...", "apitoken": "..."}
```

A list of those objects is accepted as well, for a file covering more
than one Jira; `--jira-url` picks the entry to use.

**Use `https://couchbasecloud.atlassian.net` as the URL, not
`https://jira.issues.couchbase.com`.** The vanity domain serves the UI
and some REST endpoints, but `/rest/api/2/issue/...` under it 404s even
for an issue the account can see, which looks exactly like a permissions
problem and isn't one.

The account needs to be able to see and edit the issue. Note that MB
issues can carry a security level - one the account can't see is a 404,
and shows up as an issue that "can't be updated".

The field is found by name (`--field-name`, default `Gerrit Reviews`);
`--field-id customfield_11243` skips the lookup.

## In a Jenkins job

Add the outside Gerrit as a server in the Gerrit Trigger plugin's
configuration, trigger the job on patchset-created for the projects that
matter, and turn off the plugin's own voting - this job doesn't review
anything. Then:

```bash
export JIRA_URL=https://couchbasecloud.atlassian.net
build-tools/gerrit/ext-ref-jira-link/link_ext_refs.py --update
```

Set `JIRA_URL`, or pass `--jira-url`, even if the agent has a
credentials file - if that file's `url` is the vanity domain, every
issue comes back 404. The command line wins over both.

Without `--update` the script is read-only and exits 0 having written
nothing, so a job missing it looks like a job that worked.

Triggering on ref-updated as well as patchset-created will catch changes
that were merged without the job ever having run on them.

## The field has other writers

**The Gerrit integration appends; it does not regenerate.** This was
measured, not assumed: a throwaway change referencing MB-73268 was
pushed to review.couchbase.org while the field held an entry for an
AsterixDB change, and the integration's write was a byte-for-byte append
of `\\` plus the new entry, leaving everything before it - the outside
entry included - untouched. Abandoning that change then edited its own
entry in place to add an `(x)` marker, again touching nothing else.

So an entry for an outside Gerrit is not at risk from the integration's
ordinary writes, and this job does not need to fight it.

Two things temper that. The integration writes as a WIP change is
enough to trigger it, so entries appear for changes that were never
meant to be reviewed. And the field's history shows bursts of writes
that reorder the existing entries with no net change - four in a
second, several times a day - which a pure append cannot produce. That
is a second code path, and it has not been observed with an outside
entry in the field. If entries ever do go missing, that is where to
look first.

**An automation rule blanks it on clone.** MB-73268 was cloned from
MB-73147, and `Automation for Jira` set the field to empty seconds
later, discarding the four entries the clone inherited. That one is
real and this job cannot prevent it; re-running restores the entry.

To watch for either, the issue changelog records this field in full -
`GET /rest/api/2/issue/{key}/changelog` gives `fieldId:
customfield_11243` with `fromString`, `toString` and the author, so a
watcher can see exactly what changed and who changed it. JQL is no help:
its `CHANGED` operator only supports a handful of system fields. The
alternative, if someone with project admin will set it up, is an
automation rule triggered on this field changing that calls a Jenkins
job - no polling, but it needs the rule.

## Concurrent writes

Jira offers no compare-and-swap on a field update, so two changes naming
the same issue at once can lose one another's entry. After writing, the
job re-reads the field and retries if its entry didn't survive
(`--attempts`).
