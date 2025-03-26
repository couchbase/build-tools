#!/bin/bash -ex

rm -rf couchbase-efcore-provider/tests
# Hack to avoid BD scan picking up Couchbase.EntityFrameworkCore itself.
csprojs=$(find couchbase-efcore-provider/samples -name '*.csproj')
for csproj in ${csprojs}; do
    sed -i -e "s/.*Couchbase.EntityFrameworkCore.*//g" ${csproj}
done
