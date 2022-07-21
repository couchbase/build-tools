#!/bin/bash -ex
git clone ssh://git@github.com/couchbasecloud/couchbase-cloud.git
git clone ssh://git@github.com/couchbase/direct-nebula.git
git clone ssh://git@github.com/couchbaselabs/data-api.git

for repo in couchbase-cloud direct-nebula data-api; do
    pushd ${repo}
    go mod download
    popd
done

echo "replace github.com/couchbasecloud/couchbase-cloud => ../couchbase-cloud" >> direct-nebula/go.mod
echo "replace github.com/couchbasecloud/couchbase-cloud => ../couchbase-cloud" >> data-api/go.mod
