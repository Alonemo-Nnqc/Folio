#!/usr/bin/env bash
# Captures only Folio's main window: script/window-shot.sh <output.png>
set -euo pipefail
OUT="${1:-/tmp/folio-shot.png}"
WID=$(swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "Folio" && ($0[kCGWindowLayer as String] as? Int) == 0 }
let largest = windows.max { a, b in
    let ra = a[kCGWindowBounds as String] as? [String: Double] ?? [:], rb = b[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (ra["Width"] ?? 0) * (ra["Height"] ?? 0) < (rb["Width"] ?? 0) * (rb["Height"] ?? 0)
}
if let id = largest?[kCGWindowNumber as String] as? Int { print(id) }
' 2>/dev/null)
[[ -n "$WID" ]] || { echo "Folio window not found" >&2; exit 1; }
screencapture -x -o -l "$WID" "$OUT"
sips -Z 1600 "$OUT" >/dev/null
echo "$OUT"
