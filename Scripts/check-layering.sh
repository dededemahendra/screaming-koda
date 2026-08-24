#!/bin/bash
#
# The crawler and its models must stay headless: KodaCore has to run from the
# CLI and from cron, and KodaUI has to be testable under Command Line Tools,
# where there is no UI test harness. A stray `import SwiftUI` in either breaks
# both, and does so quietly.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

status=0
for target in KodaCore KodaUI; do
  if grep -rnE '^\s*import (AppKit|SwiftUI|UIKit)' "Sources/$target" 2>/dev/null; then
    echo "FAIL: $target imports a UI framework"
    status=1
  else
    echo "ok: $target"
  fi
done
exit $status
