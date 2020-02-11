#!/bin/bash

RELEASE=$1

echo @@@@@@@@@@@@@@@@@@@@@@@@@
echo "mobile-testkit ${RELEASE}"
echo @@@@@@@@@@@@@@@@@@@@@@@@@

cloc --quiet --exclude-lang=JSON .
