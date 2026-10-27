#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_python="${VESPER_PYTHON:-$(command -v python3)}"
if (( $# > 1 )) || [[ "${1:-vesper}" != "vesper" ]]; then
    printf '%s\n' 'Usage: Scripts/BuildXcodeIPA.sh [vesper]' >&2
    exit 2
fi
task_scheme=Vesper
task_build="$PWD/.build/xcode/$task_scheme"
task_archive="$task_build/$task_scheme.xcarchive"
mkdir -p "$task_build" xtool

# Keep private symbols for the pre-strip audit and retain the archive's matching dSYMs locally.
xcodebuild archive -project "$task_scheme.xcodeproj" -scheme "$task_scheme" \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$task_build/DerivedData" -archivePath "$task_archive" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    ARCHS=arm64 STRIP_INSTALLED_PRODUCT=NO COPY_PHASE_STRIP=NO DEPLOYMENT_POSTPROCESSING=NO

task_staging=$(mktemp -d "$task_build/package.XXXXXX")
trap 'rm -rf "$task_staging"' EXIT
mkdir -p "$task_staging/Payload"
ditto "$task_archive/Products/Applications/$task_scheme.app" "$task_staging/Payload/$task_scheme.app"
task_ipa="$task_staging/$task_scheme.ipa"
(cd "$task_staging" && /usr/bin/zip -qry0 "$task_ipa" Payload)
"$task_python" -B Scripts/OptimizeIPA.py "$task_ipa"
"$task_python" -B Scripts/VerifyIPA.py "$task_ipa" --native-icon
mv "$task_ipa" "xtool/$task_scheme.ipa"
mv "$task_staging/$task_scheme.sha256" "xtool/$task_scheme.sha256"
