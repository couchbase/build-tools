#!/bin/bash

OUTDIR=$1
if [ ! -d "${OUTDIR}" ]; then
    echo "${OUTDIR} doesn't exist"
    echo "Usage: $0 <output directory>"
    exit 1
fi

if [ ! -d .repo ]; then
    echo Must run from top-level repo sync
    exit 1
fi

getgopackage() {
    pkgname=$1
    echo "...$pkgname"
    curl -o ${OUTDIR}/${pkgname} -z ${OUTDIR}/${pkgname} --progress-bar \
        http://storage.googleapis.com/golang/${pkgname}
}

echo "Extracting all used Go versions (will take 10-20 seconds)..."
for gover in $( \
    repo forall -c \
        'git grep -h GOVERSION $(git rev-list --all) -- \*CMakeLists.txt|cat' | \
    perl -lne '/(1\.[0-9]+(\.[0-9x]+)?)/ && print $1' | \
    sort -u); do

    if [ "${gover}" = "1.4.x" ]; then
        gover=1.4.2
        sillymacbit=-osx10.8
    else
        sillymacbit=
    fi

    echo "Downloading Go version ${gover}..."
    getgopackage go${gover}.darwin-amd64${sillymacbit}.tar.gz
    getgopackage go${gover}.windows-amd64.zip
    getgopackage go${gover}.linux-amd64.tar.gz
done

echo "Done!"