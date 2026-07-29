#!/bin/sh

set -eu

if [ -z "${DEVELOPER_DIR:-}" ]; then
    printf 'error: DEVELOPER_DIR must explicitly select Xcode 26.4.\n' >&2
    exit 1
fi

xcode_version="$(xcodebuild -version)"
expected_xcode_version="$(printf 'Xcode 26.4\nBuild version 17E192')"
if [ "$xcode_version" != "$expected_xcode_version" ]; then
    printf 'error: expected Xcode 26.4 build 17E192, got:\n%s\n' "$xcode_version" >&2
    exit 1
fi

swift_version="$(xcrun swift --version)"
case "$swift_version" in
    *"Apple Swift version 6.3"*) ;;
    *)
        printf 'error: expected Apple Swift 6.3, got:\n%s\n' "$swift_version" >&2
        exit 1
        ;;
esac

printf 'Validated Xcode 26.4 (17E192) and Apple Swift 6.3.\n'
