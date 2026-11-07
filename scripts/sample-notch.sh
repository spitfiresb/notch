#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/benchmarks/tools
binary=.build/benchmarks/tools/sample-notch
if [[ ! -x "$binary" || scripts/sample-notch.swift -nt "$binary" ]]; then
    swiftc -O scripts/sample-notch.swift -o "$binary"
fi
exec "$binary" "$@"
