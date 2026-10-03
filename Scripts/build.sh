#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' 'Usage: ./Scripts/build.sh' \
        'Build an ad hoc signed Release app with the locked package versions.' \
        'Output: build/Release/VoiceType.app' \
        'VOICETYPE_BUILD_DIR changes the build directory (relative to the repository).'
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
fi

if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'Building VoiceType requires macOS and Xcode 26 or later.' >&2
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
build_dir="${VOICETYPE_BUILD_DIR:-$repo_dir/build}"
if [[ "$build_dir" != /* ]]; then
    build_dir="$repo_dir/$build_dir"
fi
derived_data_dir="$build_dir/DerivedData"
release_dir="$build_dir/Release"

xcodebuild \
    -project "$repo_dir/VoiceType.xcodeproj" \
    -scheme VoiceType \
    -derivedDataPath "$derived_data_dir" \
    -configuration Release \
    -destination 'platform=macOS' \
    -disableAutomaticPackageResolution \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    build

mkdir -p -- "$release_dir"
ditto "$derived_data_dir/Build/Products/Release/VoiceType.app" "$release_dir/VoiceType.app"
codesign --verify --deep --strict "$release_dir/VoiceType.app"
printf 'Built %s\n' "$release_dir/VoiceType.app"
