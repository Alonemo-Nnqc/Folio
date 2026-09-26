#!/usr/bin/env bash
# Screenshot a UI state without touching mouse or keyboard:
#   script/preview.sh <out.png> <library dir> [app launch args…]
# The app launches in the background (open -g), only its own window is captured, then it quits.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/Folio.app"
OUT="$1"; LIB="$2"; shift 2
# Only ever stop the instance this script started (matched by its library path), never the user's Folio.
stop_mine() { pkill -f "Folio.app/Contents/MacOS/Folio -FolioLibraryPath $LIB" >/dev/null 2>&1; }
stop_mine; sleep 0.4
open -g -n "$APP" --args -FolioLibraryPath "$LIB" -FolioUITesting YES -ApplePersistenceIgnoreState YES "$@"
sleep "${FOLIO_PREVIEW_WAIT:-2.5}"
export FOLIO_PREVIEW_PID=$(pgrep -f "Folio.app/Contents/MacOS/Folio -FolioLibraryPath $LIB" | head -1)
WID=$(swift -e '
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let title = ProcessInfo.processInfo.environment["FOLIO_PREVIEW_WINDOW"] ?? ""
let pid = Int(ProcessInfo.processInfo.environment["FOLIO_PREVIEW_PID"] ?? "") ?? -1
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
  && (title.isEmpty || (($0[kCGWindowName as String] as? String) ?? "").contains(title)) }
let big = mine.max { a, b in
  let x = a[kCGWindowBounds as String] as? [String: Double] ?? [:], y = b[kCGWindowBounds as String] as? [String: Double] ?? [:]
  return (x["Width"] ?? 0) * (x["Height"] ?? 0) < (y["Width"] ?? 0) * (y["Height"] ?? 0) }
if let id = big?[kCGWindowNumber as String] as? Int { print(id) }' 2>/dev/null)
if [[ -z "$WID" ]]; then echo "no Folio window" >&2; stop_mine; exit 1; fi
screencapture -x -o -l "$WID" "$OUT" && sips -Z 1600 "$OUT" >/dev/null
[[ "${FOLIO_PREVIEW_KEEP:-0}" == "1" ]] || stop_mine
echo "$OUT"
