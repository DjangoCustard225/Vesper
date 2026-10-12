#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Only reproducible build products and generated editor/staging files.
# Keep packaged IPAs, source code, assets, signing settings, and project files.
for task_directory in .build Core/.build Dependencies/MPVKit/.build .bsp xtool/.xtool-tmp Scripts/__pycache__ Tests/__pycache__; do
    rm -rf -- "$task_directory"
done
printf '%s\n' 'Removed generated build and staging files; packaged IPAs are preserved.'
