#!/usr/bin/env bash
# Packs the browser extension for the stores (WEB-05): dist/folio-chromium-<version>.zip for the Chrome Web
# Store / Edge Add-ons, dist/folio-firefox-<version>.xpi for Mozilla signing (web-ext sign or the AMO site).
# Publishing and signing need the developer's own store accounts; Folio itself installs the unpacked folder.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/BrowserExtension"
OUT="$ROOT/dist"
VERSION=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$SRC/chromium/manifest.json")
mkdir -p "$OUT"
for family in chromium firefox; do
  STAGE=$(mktemp -d)
  cp "$SRC"/shared/* "$STAGE"/
  # The store assigns its own ID; the fixed development key only matters for unpacked installs.
  python3 - "$SRC/$family/manifest.json" "$STAGE/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
manifest.pop("key", None)
json.dump(manifest, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
PY
  EXT=$([[ $family == firefox ]] && echo xpi || echo zip)
  TARGET="$OUT/folio-$family-$VERSION.$EXT"
  rm -f "$TARGET"
  (cd "$STAGE" && zip -qr -X "$TARGET" .)
  rm -rf "$STAGE"
  echo "$TARGET"
done
