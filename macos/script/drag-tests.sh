#!/usr/bin/env bash
# Drag-and-drop acceptance tests with real mouse events (XCUITest's synthesized drags are ignored by
# NSOutlineView). Seeds a temporary library, drives the app with CGEvents and checks SQLite.
#   script/drag-tests.sh            (app must be built: script/build_and_run.sh --build-only)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/Folio.app"
WORK="$(mktemp -d /tmp/folio-drag.XXXX)"
LIB="$WORK/Library"
DB="$LIB/Folio.sqlite"
PASS=0; FAIL=0

q() { sqlite3 "$DB" "$1"; }
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "  ✔ $1"; PASS=$((PASS+1)); else echo "  ✘ $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}
launch() {
  pkill -f "DerivedData/Build/Products/Debug/Folio.app/Contents/MacOS/Folio" >/dev/null 2>&1; sleep 0.5
  open -n "$APP" --args -FolioLibraryPath "$LIB" -FolioUITesting YES -ApplePersistenceIgnoreState YES
  sleep 3
  read -r WX WY < <(swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Folio" && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as! [String: Double]; print(Int(b["X"]!), Int(b["Y"]!)); break
}' 2>/dev/null)
}
drag() { swift "$ROOT/script/mouse-drag.swift" "$1" "$2" "$3" "$4" 2>/dev/null; sleep 1.2; }

# Layout offsets inside the 1280×800 window (points): list rows start at y=85 (26 tall), sidebar
# built-ins at 78/106/134 (28 tall), divider 162–175, user groups from 175 (28 tall).
LIST_X=330; SIDEBAR_X=100
listRow() { echo $((WY + 98 + 26 * $1)); }
builtinRow() { echo $((WY + 92 + 28 * $1)); }
groupRow() { echo $((WY + 189 + 28 * $1)); }

echo "▶ seeding $LIB"
launch; pkill -f "DerivedData/Build/Products/Debug/Folio.app/Contents/MacOS/Folio"; sleep 1
q "INSERT INTO libraryGroup (id, parentId, name, position, dateCreated) VALUES
   ('gA', NULL, 'Alpha', 0, '2026-09-26 12:00:00.000'), ('gB', NULL, 'Beta', 1, '2026-09-26 12:00:00.000'),
   ('gC', NULL, 'Gamma', 2, '2026-09-26 12:00:00.000');
   INSERT INTO tag (id, name, colorHex, position) VALUES ('t1', 'Must-read', '#FF3B30', 0);"
launch
for n in one two three; do echo "$n" > "$WORK/$n.txt"; done
open -a "$APP" "$WORK/one.txt"; sleep 0.6; open -a "$APP" "$WORK/two.txt"; sleep 0.6; open -a "$APP" "$WORK/three.txt"; sleep 2
check "three standalone files imported" 3 "$(q 'SELECT count(*) FROM item')"
FIRST=$(q "SELECT id FROM item ORDER BY dateAdded DESC LIMIT 1")

echo "▶ DND-03 item → group"
drag $((WX + LIST_X)) "$(listRow 0)" $((WX + SIDEBAR_X)) "$(groupRow 0)"
check "newest item added to Alpha" "$FIRST" "$(q "SELECT itemId FROM itemGroup WHERE groupId='gA'")"

echo "▶ DND-03 item → tag"
# built-ins, divider, 3 groups (175–259), "标签" header (259–285), first tag row centred at 299.
drag $((WX + LIST_X)) "$(listRow 1)" $((WX + SIDEBAR_X)) $((WY + 299))
check "second item tagged" 1 "$(q "SELECT count(*) FROM itemTag WHERE tagId='t1'")"

echo "▶ DND-04 reorder rows"
drag $((WX + LIST_X)) "$(listRow 0)" $((WX + LIST_X)) $(( $(listRow 2) + 11 ))
check "custom order written for 所有文献" 3 "$(q "SELECT count(*) FROM itemOrder WHERE scope='all'")"
check "dragged item is now last" "$FIRST" "$(q "SELECT itemId FROM itemOrder WHERE scope='all' ORDER BY position DESC LIMIT 1")"

echo "▶ SIDE-12 group onto group (nest)"
drag $((WX + SIDEBAR_X)) "$(groupRow 2)" $((WX + SIDEBAR_X)) "$(groupRow 0)"
check "Gamma became a child of Alpha" "gA" "$(q "SELECT parentId FROM libraryGroup WHERE id='gC'")"

echo "▶ SIDE-12 reorder top-level groups"
# Rows now: Alpha (collapsed, child Gamma), Beta. Drag Beta onto the gap above Alpha.
drag $((WX + SIDEBAR_X)) "$(groupRow 1)" $((WX + SIDEBAR_X)) $(( $(groupRow 0) - 12 ))
check "Beta moved to the top" "gB" "$(q "SELECT id FROM libraryGroup WHERE parentId IS NULL ORDER BY position LIMIT 1")"

echo "▶ SIDE-03 groups cannot go above the built-ins"
drag $((WX + SIDEBAR_X)) "$(groupRow 0)" $((WX + SIDEBAR_X)) $(( $(builtinRow 0) - 10 ))
check "top-level groups still present" 2 "$(q "SELECT count(*) FROM libraryGroup WHERE parentId IS NULL")"
check "Beta is still the first user group" "gB" "$(q "SELECT id FROM libraryGroup WHERE parentId IS NULL ORDER BY position LIMIT 1")"

echo "▶ TRASH-10 item → 回收站"
drag $((WX + LIST_X)) "$(listRow 0)" $((WX + SIDEBAR_X)) "$(builtinRow 2)"
check "one item trashed" 1 "$(q "SELECT count(*) FROM item WHERE trashedAt IS NOT NULL")"

pkill -f "DerivedData/Build/Products/Debug/Folio.app/Contents/MacOS/Folio"
echo "drag tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
