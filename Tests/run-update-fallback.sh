#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpus2-update-fallback.XXXXXX")"
cleanup() {
    python3 - "$TEST_TMP" <<'PY'
import os
from pathlib import Path
import shutil
import sys

temporary = Path(sys.argv[1])
if temporary.name.startswith("cpus2-update-fallback.") and not temporary.is_symlink():
    details = temporary.stat()
    if temporary.is_dir() and details.st_uid == os.getuid() and details.st_mode & 0o077 == 0:
        shutil.rmtree(temporary)
PY
}
trap cleanup EXIT

echo "Building offline GitHub release fallback checks"
swiftc -Onone -warnings-as-errors -swift-version 5 \
    "$PROJECT_DIR/Sources/UpdateCore.swift" "$PROJECT_DIR/Sources/UpdateFallback.swift" \
    "$TEST_DIR/UpdateFallbackTests.swift" \
    -framework Foundation -framework CryptoKit -lz -o "$TEST_TMP/update-fallback-tests"
"$TEST_TMP/update-fallback-tests"
