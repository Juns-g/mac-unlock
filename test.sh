#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$#" -le 1 ] || { echo 'Usage: sh test.sh [output-directory]' >&2; exit 64; }
output=${1:-"$root/build/tests"}
mkdir -p "$output/evidence"
output=$(CDPATH= cd -- "$output" && pwd)
cd "$root"
swiftc -O src/Policy.swift src/Native.swift tests/tests.swift -o "$output/checks"
cd "$output"
./checks
