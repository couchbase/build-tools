#!/bin/bash -ex
git clone ssh://git@github.com/couchbasecloud/couchbase-cloud.git
git clone ssh://git@github.com/couchbase/direct-nebula.git
git clone ssh://git@github.com/couchbase/data-api.git
git clone ssh://git@github.com/couchbase/regulator.git ../extra/regulator

for repo in couchbase-cloud direct-nebula data-api; do
    pushd ${repo}
    go mod download
    popd
done

echo "replace github.com/couchbasecloud/couchbase-cloud => ../couchbase-cloud" >> direct-nebula/go.mod
echo "replace github.com/couchbasecloud/couchbase-cloud => ../couchbase-cloud" >> data-api/go.mod
echo "replace github.com/couchbase/regulator => ../../extra/regulator" >> data-api/go.mod
echo "replace github.com/couchbase/regulator => ../../extra/regulator" >> direct-nebula/go.mod
