#!/bin/bash

# If we don't install the requirements, setup.py will dump them in
# .eggs, which then gets scanned by the Black Duck scanner (which still
# gets the components wrong). Put it in the special bd-venv which
# run-scanner looks for
python -m venv ../bd-venv
. ../bd-venv/bin/activate
pip3 install --upgrade pip
pip3 install -r couchbase-python-client/requirements.txt
