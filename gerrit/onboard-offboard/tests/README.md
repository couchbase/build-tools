Gerrit is awkward to automate around, however `run_test.sh` aims to guide you
through all the manual steps required as it progresses.

To begin with however, you will need to provide an existing github organisation
which will serve as the test org, and the name of a gerrit group (which will be
created automatically if it does not exist) and pass these to the script with
e.g.

`./run_test.sh --group foo --org bar`

The script will then set up a local gerrit instance, create a group, add a
user to that group, and remove your user account (which was added
automatically at creation), it will then run the main script (app.py) with
--dry-run, this will notify you of the actions it would take, i.e. add any
users from your test org to the gerrit group, and remove the test user (which
is local only, and not in your org)

You can retrigger `./run_test.sh --group foo --org bar -w` to disable dry-run
and allow the script to make changes.
