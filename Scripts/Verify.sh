#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/vesper-cache}"
if (( $# > 1 )) || [[ "${1:-vesper}" != "vesper" ]]; then
    printf '%s\n' 'Usage: Scripts/Verify.sh [vesper]' >&2
    exit 2
fi
bash Scripts/Format.sh --check
swift Scripts/GenerateXcodeProject.swift --check
task_arguments=(-Xswiftc -warnings-as-errors)
if [[ "${VESPER_NATIVE_BUILD:-0}" == "1" ]]; then
    task_arguments+=(--build-system native)
fi
swift test "${task_arguments[@]}" --package-path Core \
    --cache-path "$XDG_CACHE_HOME/swiftpm" \
    --scratch-path "${VESPER_TEST_SCRATCH:-/tmp/vesper-verification-core}"
task_python="${VESPER_PYTHON:-$(command -v python3)}"
"$task_python" -B Scripts/TestIPAPackaging.py
"$task_python" -B Scripts/TestAetherPlayback.py
"$task_python" -B Scripts/TestAetherRateTransitions.py
"$task_python" -B Scripts/TestPiPLifecycle.py
bash Scripts/BuildIPA.sh
"$task_python" -B Scripts/VerifyIPA.py
git diff --check
