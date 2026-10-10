#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/vesper-cache}"
if [[ "${VESPER_NATIVE_BUILD:-0}" == "1" ]]; then
    task_python="${VESPER_PYTHON:-$(command -v python3)}"
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
xtool dev build -c release --triple arm64-apple-ios27.0 --ipa
