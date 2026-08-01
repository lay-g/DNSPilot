#!/bin/sh

set -eu

repository_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
derived_data_path="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/DNSPilot-CI-Tests}"
cd "$repository_root"

"$repository_root/scripts/check-toolchain.sh"

DNSPILOT_UNIT_TEST_HOST=1 xcodebuild test -quiet \
    -project DNSPilot.xcodeproj \
    -scheme "DNSPilot Community" \
    -configuration Community \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$derived_data_path" \
    IDENTITY_TEAM_IDENTIFIER=ABCDE12345 \
    IDENTITY_BUNDLE_ID_PREFIX=org.example \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ENABLE_TESTABILITY=YES \
    ENABLE_USER_SCRIPT_SANDBOXING=NO \
    -parallel-testing-enabled NO \
    -only-testing:DNSPilotTests
