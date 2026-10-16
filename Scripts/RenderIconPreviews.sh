#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
task_tool="${task_developer%/Developer}/Applications/Icon Composer.app/Contents/Executables/ictool"
task_output="${1:-xtool/icon-previews}"
mkdir -p "$task_output"
for appearance in Default Dark ClearLight ClearDark TintedLight TintedDark; do
    "$task_tool" Vesper/VesperIcon.icon --export-image --output-file "$task_output/$appearance.png" \
        --platform iOS --rendition "$appearance" --width 1024 --height 1024 --scale 1
done
