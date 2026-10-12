#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/vesper-cache}"
task_arguments=()
if [[ "${VESPER_NATIVE_BUILD:-0}" == "1" ]]; then
    task_arguments+=(--build-system native)
fi
swift test "${task_arguments[@]}" --package-path Core \
    --cache-path "$XDG_CACHE_HOME/swiftpm" \
    --scratch-path "${VESPER_TEST_SCRATCH:-/tmp/vesper-verification-core}"
task_python="${VESPER_PYTHON:-$(command -v python3)}"
"$task_python" -B Scripts/TestMPVPlayback.py
bash Scripts/BuildIPA.sh
"$task_python" -B Scripts/VerifyIPA.py
git diff --check
