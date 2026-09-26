#!/usr/bin/env bash
# Runs the XCUITest suite (optionally one class/test): script/ui-test.sh [FolioUITests/SidebarUITests]
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
pkill -x Folio >/dev/null 2>&1 || true
xcodegen generate --quiet
ONLY="${1:-FolioUITests}"
xcodebuild -project Folio.xcodeproj -scheme Folio -derivedDataPath build/DerivedData -destination 'platform=macOS' \
  -allowProvisioningUpdates test -only-testing:"$ONLY" > /tmp/folio-uitest.log 2>&1
STATUS=$?
grep -E "^Test Case .*(passed|failed)|: error: -\[|^\*\* TEST|\.swift:[0-9]+:[0-9]+: error" /tmp/folio-uitest.log | sed 's#^/.*/FolioUITests/#  #' | head -80
exit $STATUS
