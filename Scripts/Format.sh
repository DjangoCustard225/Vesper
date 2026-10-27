#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:---check}" in
    --check) task_action=(lint --strict) ;;
    --write) task_action=(format --in-place) ;;
    *) printf '%s\n' 'Usage: Scripts/Format.sh [--check|--write]' >&2; exit 2 ;;
esac
# Visit shared source once. Vendor packages and downloaded frameworks retain their upstream formatting.
swift format "${task_action[@]}" --recursive --parallel \
    Vesper Core/Sources Core/Tests Tests \
    Package.swift Core/Package.swift \
    Scripts/GenerateXcodeProject.swift
