#!/bin/sh

set -eu

repository_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"

"$repository_root/scripts/ci/check-repository.sh"
"$repository_root/scripts/ci/test.sh"
"$repository_root/scripts/ci/analyze.sh"
"$repository_root/scripts/ci/build.sh"
