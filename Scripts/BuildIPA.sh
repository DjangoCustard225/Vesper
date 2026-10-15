#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/vesper-cache}"
task_python="${VESPER_PYTHON:-$(command -v python3)}"
task_edition="${1:-vesper}"
case "$task_edition" in
    vesper)
        "$task_python" -B Scripts/PrepareMPVKit.py
        "$task_python" -B Scripts/PrepareMPVFramework.py
        "$task_python" -B Scripts/PrepareAetherEngine.py
        ;;
    go) ;;
    *) printf '%s\n' 'Usage: Scripts/BuildIPA.sh [vesper|go]' >&2; exit 2 ;;
esac
if [[ "${VESPER_NATIVE_BUILD:-0}" == "1" ]]; then
    task_root="$PWD"
    task_adapter=$(mktemp -d /tmp/vesper-build-adapter.XXXXXX)
    trap 'rm -rf "$task_adapter"' EXIT
    for tool in build package; do
        {
            printf '#!/usr/bin/env bash\n'
            printf 'exec %q -B %q %q "$@"\n' "$task_python" "$task_root/Scripts/NativeSwiftPM.py" "$tool"
        } > "$task_adapter/swift-$tool"
        chmod +x "$task_adapter/swift-$tool"
    done
    export SWIFTPM_CUSTOM_BIN_DIR="$task_adapter"
fi
if [[ "$task_edition" == "go" ]]; then cd Go; fi
xtool dev build -c release --triple arm64-apple-ios27.0 --ipa
if [[ "$task_edition" == "go" ]]; then
    mkdir -p ../xtool
    mv xtool/VesperGo.ipa ../xtool/VesperGo.ipa
fi
