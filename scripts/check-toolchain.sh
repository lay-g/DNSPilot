#!/bin/sh

set -eu

# Minimum supported toolchain. Newer Xcode and Swift releases are accepted.
minimum_xcode_version="26.4"
minimum_swift_version="6.3"

# Succeeds when dotted version $1 is greater than or equal to $2.
version_at_least() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}

xcode_version_output="$(xcodebuild -version)"
xcode_version="$(printf '%s\n' "$xcode_version_output" | sed -n 's/^Xcode \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
if [ -z "$xcode_version" ] || ! version_at_least "$xcode_version" "$minimum_xcode_version"; then
    printf 'error: expected Xcode %s or later, got:\n%s\n' "$minimum_xcode_version" "$xcode_version_output" >&2
    exit 1
fi

swift_version_output="$(xcrun swift --version 2>&1)"
swift_version="$(printf '%s\n' "$swift_version_output" | sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
if [ -z "$swift_version" ] || ! version_at_least "$swift_version" "$minimum_swift_version"; then
    printf 'error: expected Apple Swift %s or later, got:\n%s\n' "$minimum_swift_version" "$swift_version_output" >&2
    exit 1
fi

printf 'Validated Xcode %s and Apple Swift %s.\n' "$xcode_version" "$swift_version"
