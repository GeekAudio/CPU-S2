#!/bin/bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_dir="$(cd -- "$test_dir/.." && pwd -P)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cpus2-update-manager-tests.XXXXXX")"
chmod 700 "$test_tmp"
cleanup() {
  case "$test_tmp" in
    "${TMPDIR:-/tmp}"/cpus2-update-manager-tests.*) rm -rf -- "$test_tmp" ;;
    *) echo "Refusing to remove unexpected test path: $test_tmp" >&2; exit 1 ;;
  esac
}
trap cleanup EXIT

echo "Building offline update-manager lifecycle checks"
xcrun swiftc -Onone -warnings-as-errors -swift-version 5 \
  "$project_dir/Sources/UpdateCore.swift" \
  "$project_dir/Sources/UpdateFallback.swift" \
  "$project_dir/Sources/UpdateInstallerCore.swift" \
  "$project_dir/Sources/UpdateInstaller.swift" \
  "$project_dir/Sources/UpdateManager.swift" \
  "$test_dir/UpdateManagerTests.swift" \
  -framework Foundation -framework CryptoKit -lz \
  -o "$test_tmp/update-manager-tests"
"$test_tmp/update-manager-tests"
