#!/usr/bin/env bash
# Kill → build → launch Folio. Flags: --verify, --logs, --debug, --release, --build-only
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Folio"
BUNDLE_ID="com.nnqc.Folio"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="Debug"
[[ "$MODE" == "--release" ]] && CONFIG="Release"
DERIVED="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
xcodegen generate --quiet
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' -allowProvisioningUpdates \
  build 2>&1 | grep -E "error:|warning: .*Folio/|BUILD (SUCCEEDED|FAILED)" || true
[[ -d "$APP_BUNDLE" ]] || { echo "build failed: $APP_BUNDLE missing" >&2; exit 1; }

open_app() { /usr/bin/open -n "$APP_BUNDLE" --args "${FOLIO_ARGS[@]:-}"; }
FOLIO_ARGS=()
[[ -n "${FOLIO_LIBRARY:-}" ]] && FOLIO_ARGS=(-FolioLibraryPath "$FOLIO_LIBRARY")

case "$MODE" in
  run|--release) open_app ;;
  --build-only|build) echo "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) open_app; sleep 2; pgrep -x "$APP_NAME" >/dev/null && echo "running: $(pgrep -x $APP_NAME)" ;;
  *) echo "usage: $0 [run|--verify|--logs|--telemetry|--debug|--release|--build-only]" >&2; exit 2 ;;
esac
