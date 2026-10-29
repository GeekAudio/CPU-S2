#!/bin/bash
# No CPU stress test: C entry points are replaced by aborting stubs.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpus2-tests.XXXXXX")"
cleanup() {
    python3 - "$TEST_TMP" <<'PY'
import os
from pathlib import Path
import shutil
import sys

temporary = Path(sys.argv[1])
# The sole deletion target is this script's freshly created, private mktemp directory.
if temporary.name.startswith("cpus2-tests.") and not temporary.is_symlink():
    details = temporary.stat()
    if temporary.is_dir() and details.st_uid == os.getuid() and details.st_mode & 0o077 == 0:
        shutil.rmtree(temporary)
PY
}
trap cleanup EXIT

echo "Checking Probe.c for x86_64 and arm64 (macOS 11 deployment target)"
for TEST_ARCH in x86_64 arm64; do
    clang -Wall -Wextra -Werror -O2 -arch "$TEST_ARCH" -mmacosx-version-min=11.0 \
        -c "$PROJECT_DIR/Sources/Probe.c" -o "$TEST_TMP/probe-$TEST_ARCH.o"
done

echo "Building parser, statistics, and process cancellation regressions"
clang -Wall -Wextra -Werror -c "$TEST_DIR/ProbeStubs.c" -o "$TEST_TMP/probe-stubs.o"
swiftc -Onone -swift-version 5 \
    "$PROJECT_DIR/Sources/Engine.swift" "$TEST_DIR/main.swift" "$TEST_TMP/probe-stubs.o" \
    -framework Foundation -framework IOKit -o "$TEST_TMP/engine-tests"
"$TEST_TMP/engine-tests" "$TEST_DIR/Fixtures"

echo "Building immutable report snapshot, CSV, and JSON regressions"
swiftc -Onone -swift-version 5 \
    "$PROJECT_DIR/Sources/Engine.swift" "$PROJECT_DIR/Sources/CPUCoreInfo.swift" \
    "$PROJECT_DIR/Sources/IntelCoreCatalog.swift" "$PROJECT_DIR/Sources/ReportWriter.swift" \
    "$TEST_DIR/ReportWriterTests.swift" "$TEST_TMP/probe-stubs.o" \
    -framework Foundation -framework IOKit -o "$TEST_TMP/report-tests"
"$TEST_TMP/report-tests"

echo "Building Intel core topology classification regressions"
swiftc -Onone -swift-version 5 \
    "$PROJECT_DIR/Sources/Engine.swift" "$PROJECT_DIR/Sources/CPUCoreInfo.swift" \
    "$PROJECT_DIR/Sources/IntelCoreCatalog.swift" "$PROJECT_DIR/Sources/ReportWriter.swift" \
    "$TEST_DIR/CPUCoreInfoTests.swift" "$TEST_TMP/probe-stubs.o" \
    -framework Foundation -framework IOKit -o "$TEST_TMP/core-info-tests"
"$TEST_TMP/core-info-tests"
