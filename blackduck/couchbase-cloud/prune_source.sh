#!/bin/bash

find . -type d -name example\* -print0 | xargs -0 rm -rf
