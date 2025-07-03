#!/bin/bash

find . -depth -type d -name documentation -print0 | xargs -0 rm -rf