# Testing patch_via_gerrit

These tests aim to cover at least the basic things we don't want to break.

To start, create a virtualenv

```shell
python3 -m venv venv
source venv/bin/activate
```

Install package requirements, pytest and pytest-cov

```shell
pip3 install -r requirements.txt
pip3 install pytest pytest-cov
```

Pull source to a target folder:

```shell
mkdir /tmp/code
(
    cd /tmp/code
    repo init --no-repo-verify --repo-url=git://github.com/couchbasedeps/git-repo -u git://github.com/couchbase/manifest -m couchbase-server/cheshire-cat.xml -g all '--reference=~/reporef'
    repo sync --jobs=8
)
```

Run the tests,

```shell
source_path=/tmp/code gerrit_url=http://example.com gerrit_user=user gerrit_pass=pass pytest --cov=gerrit_tools -s -v
```
