#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/cpus2-installer-tests.XXXXXX")"
chmod 700 "$test_root"
cleanup() {
  case "$test_root" in
    "${TMPDIR:-/tmp}"/cpus2-installer-tests.*) rm -rf -- "$test_root" ;;
    *) echo "Refusing to remove unexpected test path: $test_root" >&2; exit 1 ;;
  esac
}
trap cleanup EXIT

clang -Werror -Wall -o "$test_root/fixture" "$repo_root/Tests/Fixtures/updater/fixture.c"
if /usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null | grep -q '^1$'; then
  foreign_arch="x86_64"
else
  foreign_arch="arm64"
fi
clang -arch "$foreign_arch" -Werror -Wall -o "$test_root/fixture-foreign" "$repo_root/Tests/Fixtures/updater/fixture.c"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$repo_root/Sources/UpdateInstallerCore.swift" \
  "$repo_root/Tests/Fixtures/updater/ack-app.swift" \
  -o "$test_root/ack-app-executable"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$repo_root/Sources/UpdateInstallerCore.swift" \
  "$repo_root/Tests/UpdateInstallerTests.swift" \
  -o "$test_root/installer-tests"
"$test_root/installer-tests" "$test_root/fixture" "$test_root/fixture-foreign" \
  "$test_root/ack-app-executable" "$test_root/fixtures"
