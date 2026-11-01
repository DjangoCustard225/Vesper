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
    --scratch-path "${VESPER_TEST_SCRATCH:-/tmp/vesper-usenet-core}"
swift test "${task_arguments[@]}" --package-path Packages/UsenetEngine --scratch-path "${VESPER_USENET_TEST_SCRATCH:-/tmp/vesper-usenet-engine-tests}"
swift test "${task_arguments[@]}" --package-path Packages/DownloadEngine --scratch-path "${VESPER_DOWNLOAD_ENGINE_TEST_SCRATCH:-/tmp/vesper-download-engine-tests}"
if [[ "$(uname -s)" == "Darwin" ]]; then
    swift test --package-path Packages/PAR2Kit --scratch-path "${VESPER_PAR2_TEST_SCRATCH:-/tmp/vesper-par2-tests}"
fi
task_python="${VESPER_PYTHON:-$(command -v python3)}"
"$task_python" -B Scripts/TestIPAPackaging.py
"$task_python" -B Scripts/TestAetherPlayback.py
"$task_python" -B Scripts/TestAetherRateTransitions.py
"$task_python" -B Scripts/TestPiPLifecycle.py
"$task_python" -B Scripts/TestNowPlaying.py
"$task_python" -B Scripts/TestDownloadLifecycle.py
"$task_python" -B Scripts/TestHTTPDownloads.py
"$task_python" -B Scripts/TestDownloadBackground.py
"$task_python" -B Scripts/TestDownloadPostprocessing.py
"$task_python" -B Scripts/TestUsenetImport.py
bash Scripts/BuildIPA.sh
"$task_python" -B Scripts/VerifyIPA.py
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git diff --check; fi
