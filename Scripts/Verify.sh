#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/vesper-cache}"
task_edition="${1:-vesper}"
case "$task_edition" in vesper|go) ;; *) printf '%s\n' 'Usage: Scripts/Verify.sh [vesper|go]' >&2; exit 2 ;; esac
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
task_verification_arguments=()
if [[ "$task_edition" == "vesper" ]]; then
    "$task_python" -B Scripts/TestMPVPlayback.py
    "$task_python" -B Scripts/TestAetherPlayback.py
else
    task_verification_arguments+=(--go)
    swift test "${task_arguments[@]}" --package-path Go/Core \
        --cache-path "$XDG_CACHE_HOME/swiftpm" \
        --scratch-path "${VESPER_TEST_SCRATCH:-/tmp/vesper-verification-core}-go"
fi
bash Scripts/BuildIPA.sh "$task_edition"
if ((${#task_verification_arguments[@]})); then
    "$task_python" -B Scripts/VerifyIPA.py "${task_verification_arguments[@]}"
else
    "$task_python" -B Scripts/VerifyIPA.py
fi
git diff --check
