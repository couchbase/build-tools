#!/bin/bash -ex
rm -rf build manifest.xml
pushd vulcan-core/libs/vulcan/extractor
pip install -r requirements.txt
popd
