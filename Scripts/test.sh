#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' 'Usage: ./Scripts/test.sh' \
        'Compile and run the five local regression tests on macOS.'
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
fi

if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'These tests require macOS and Xcode.' >&2
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/voicetype-tests.XXXXXX")"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

run_test() {
    local name="$1"
    local source="$2"
    printf 'Running %s...\n' "$name"
    # Keep assertions enabled; these tests use assert rather than XCTest.
    xcrun --sdk macosx swiftc -swift-version 5 -Onone -sdk "$sdk_path" \
        "$repo_dir/VoiceType/$source" "$repo_dir/Tests/$name.swift" \
        -o "$test_dir/$name"
    "$test_dir/$name"
}

# Each test is a separate @main program. No recording or API calls are made.
run_test HotKeyGestureTests HotKeyManager.swift
run_test HistoryStoreTests HistoryStore.swift
run_test StreamingTranscriptTests StreamingTranscript.swift
run_test RecognitionAudioTests StreamingTranscript.swift
run_test DictionaryEditorTests DictionaryEditor.swift
printf '%s\n' 'All five regression tests passed.'
