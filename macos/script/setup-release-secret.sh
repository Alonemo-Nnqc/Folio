#!/usr/bin/env bash
# Copies the Sparkle EdDSA private key (login keychain, account "Folio") into the GitHub repository
# secret SPARKLE_ED_PRIVATE_KEY, which the Release workflow uses to sign updates. Run once per repository:
#   script/setup-release-secret.sh [owner/repo]
# Keep a backup of the key too (generate_keys --account Folio -x <file>): without it, installed copies
# can no longer accept updates.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-Alonemo-Nnqc/Folio}"
BIN=$(ls -d "$ROOT"/build/*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)
[[ -n "$BIN" ]] || { echo "Sparkle tools not found; build Folio once first (script/build_and_run.sh --build-only)" >&2; exit 1; }
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
rm -f "$KEY_FILE"
"$BIN/generate_keys" --account Folio -x "$KEY_FILE" >/dev/null
gh secret set SPARKLE_ED_PRIVATE_KEY --repo "$REPO" < "$KEY_FILE"
echo "SPARKLE_ED_PRIVATE_KEY set for $REPO"
