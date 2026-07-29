#!/bin/sh

set -eu

repository_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repository_root"

required_files="
LICENSE
NOTICE
README.md
README.zh-CN.md
CONTRIBUTING.md
SECURITY.md
PRIVACY.md
BRANDING.md
SUPPORT.md
CHANGELOG.md
CODE_OF_CONDUCT.md
THIRD-PARTY-NOTICES.md
Configurations/Community.xcconfig
Configurations/Identity.local.xcconfig.example
docs/en/README.md
docs/zh/README.md
"

for path in $required_files; do
    if [ ! -f "$path" ]; then
        printf 'error: required public file is missing: %s\n' "$path" >&2
        exit 1
    fi
done

list_language_docs() {
    language="$1"
    find "docs/$language" -type f -name '*.md' -print |
        while IFS= read -r path; do
            printf '%s\n' "${path#docs/$language/}"
        done |
        LC_ALL=C sort -u
}

english_docs="$(list_language_docs en)"
chinese_docs="$(list_language_docs zh)"
if [ "$english_docs" != "$chinese_docs" ]; then
    printf 'error: docs/en and docs/zh must have matching Markdown paths\n' >&2
    printf 'English paths:\n%s\nChinese paths:\n%s\n' "$english_docs" "$chinese_docs" >&2
    exit 1
fi

git diff --check

if git ls-files --error-unmatch Configurations/Identity.local.xcconfig >/dev/null 2>&1; then
    printf 'error: local signing identity configuration is tracked\n' >&2
    exit 1
fi

user_paths="$(git grep -n -I -E '/Users/[^/[:space:]]+' -- . ':!scripts/ci/check-repository.sh' || true)"
user_paths="$(printf '%s\n' "$user_paths" | grep -v '/Users/Shared' || true)"
if [ -n "$user_paths" ]; then
    printf '%s\n' "$user_paths"
    printf 'error: public files contain a user-specific absolute path\n' >&2
    exit 1
fi

if git grep -n -I -E 'ProfileEntitlement|entitlementRestricted|STOREKIT_PRODUCT_IDENTIFIER|Free plan supports' -- '*.swift' '*.xcconfig'; then
    printf 'error: obsolete commercial policy remains in production or tests\n' >&2
    exit 1
fi

if git grep -n -I -E 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' -- DNSPilot.xcodeproj/project.pbxproj; then
    printf 'error: project.pbxproj hard-codes an Apple Team identifier\n' >&2
    exit 1
fi

if git grep -n -I -E '^(APP_BUNDLE_IDENTIFIER|DNS_PROXY_BUNDLE_IDENTIFIER|APP_GROUP_IDENTIFIER) = ' -- 'Configurations/*.xcconfig' \
    | grep -v -F '$('; then
    printf 'error: xcconfig hard-codes a build identity\n' >&2
    exit 1
fi

if ! git grep -q 'revision = 5570e10e4883f9fe770a291b4025449127185f88' -- DNSPilot.xcodeproj/project.pbxproj; then
    printf 'error: DnsLibs revision is not pinned to the reviewed artifact\n' >&2
    exit 1
fi

printf 'Repository policy checks passed.\n'
