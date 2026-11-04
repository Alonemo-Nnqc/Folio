#!/usr/bin/env bash
# Cold-launch time (launch → first rows shown) and memory, app launched in the background:
#   script/perf.sh <library dir> [runs]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Release/Folio.app"
LIB="$1"; RUNS="${2:-3}"; LOG="$(mktemp /tmp/folio-perf.XXXX)"
for run in $(seq 1 "$RUNS"); do
  pkill -f "Release/Folio.app/Contents/MacOS/Folio" >/dev/null 2>&1; sleep 1; rm -f "$LOG"
  START=$(python3 -c 'import time; print(time.time())')
  open -g -n "$APP" --args -FolioLibraryPath "$LIB" -FolioUITesting YES -ApplePersistenceIgnoreState YES -FolioPerfLog "$LOG"
  for _ in $(seq 1 100); do [[ -s "$LOG" ]] && break; sleep 0.05; done
  read -r READY ROWS < "$LOG"
  sleep 4
  PID=$(pgrep -f "Release/Folio.app/Contents/MacOS/Folio" | head -1)
  FOOT=$(footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}')
  RSS=$(ps -o rss= -p "$PID" | awk '{printf "%.0f MB", $1/1024}')
  python3 -c "print(f'run $run: first rows after {($READY - $START)*1000:.0f} ms ({int($ROWS)} rows), footprint $FOOT, rss $RSS')"
done
pkill -f "Release/Folio.app/Contents/MacOS/Folio"
