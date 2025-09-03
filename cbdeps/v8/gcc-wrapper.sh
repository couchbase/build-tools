#!/usr/bin/env bash
if [ "$1" = "g++" ]; then
    shift  # Remove g++ from arguments
    exec g++ "$@" -flax-vector-conversions
else
    shift  # Remove gcc from arguments
    exec gcc "$@" -flax-vector-conversions
fi
