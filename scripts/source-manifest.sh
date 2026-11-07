#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Hash build/test/packaging inputs, including new files, but never build products.
git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' file; do
    case "$file" in
        Sources/*|Tests/*|Resources/*|scripts/*|build.sh|Package.swift|Package.resolved|PRIVACY.md|docs/INSTALL.txt|LICENSE)
            if [[ -f "$file" ]]; then shasum -a 256 "$file"; fi
            ;;
    esac
done
