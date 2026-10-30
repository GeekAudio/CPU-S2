#!/bin/bash
# Native view state only: hardware entry points abort through ProbeStubs.c.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpus2-ui-tests.XXXXXX")"
cleanup() {
    python3 - "$TEST_TMP" <<'PY'
import os
from pathlib import Path
import shutil
import sys

temporary = Path(sys.argv[1])
# Only remove this executable's freshly created, private temporary directory.
if temporary.name.startswith("cpus2-ui-tests.") and not temporary.is_symlink():
    details = temporary.stat()
    if temporary.is_dir() and details.st_uid == os.getuid() and details.st_mode & 0o077 == 0:
        shutil.rmtree(temporary)
PY
}
trap cleanup EXIT

echo "Building no-load AppKit visibility and hardware field regressions"
clang -Wall -Wextra -Werror -mmacosx-version-min=11.0 -c "$TEST_DIR/ProbeStubs.c" -o "$TEST_TMP/probe-stubs.o"
swiftc -Onone -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
    "$PROJECT_DIR/Sources/Engine.swift" "$PROJECT_DIR/Sources/CPUCoreInfo.swift" \
    "$PROJECT_DIR/Sources/ReportWriter.swift" \
    "$PROJECT_DIR/Sources/Views.swift" "$PROJECT_DIR/Sources/ThemeControls.swift" "$PROJECT_DIR/Sources/DashboardComponents.swift" \
    "$PROJECT_DIR/Sources/DeviceInfoView.swift" "$PROJECT_DIR/Sources/SettingsView.swift" "$PROJECT_DIR/Sources/DashboardView.swift" \
    "$TEST_DIR/DashboardVisibilityTests.swift" "$TEST_TMP/probe-stubs.o" \
    -framework AppKit -framework Foundation -framework IOKit -o "$TEST_TMP/dashboard-tests"
"$TEST_TMP/dashboard-tests"
