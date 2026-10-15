#!/usr/bin/env bash
# Builds a release of Folio and everything Sparkle needs to offer it as an update:
#   script/release.sh <version>            e.g. script/release.sh 1.2.0
#
# Output in dist/:
#   Folio-<version>.zip     the update archive (Sparkle) and a plain download
#   Folio-<version>.dmg     the drag-to-Applications disk image
#   appcast.xml             the update feed, attached to the GitHub release
#   release-notes.md        this version's section of CHANGELOG.md
#
# The app is ad-hoc signed (no Apple Developer Program needed). The archive is signed with the Sparkle
# EdDSA key: from $SPARKLE_ED_PRIVATE_KEY when set (CI), otherwise from the login keychain (account
# "Folio", created by Sparkle's generate_keys). Set FOLIO_DOWNLOAD_BASE to point the feed at another
# server when testing an update locally.
set -euo pipefail

VERSION="${1:?usage: script/release.sh <version>}"
VERSION="${VERSION#v}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-Alonemo-Nnqc/Folio}"
DOWNLOAD_BASE="${FOLIO_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$VERSION}"
DERIVED="$ROOT/build/ReleaseDerivedData"
OUT="$ROOT/dist"
APP="$DERIVED/Build/Products/Release/Folio.app"
# Sparkle compares CFBundleVersion, so it has to grow with every release: the commit count does.
BUILD="${FOLIO_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"

cd "$ROOT"
echo "▶ Folio $VERSION (build $BUILD)"
xcodegen generate --quiet
rm -rf "$DERIVED/Build/Products/Release"
xcodebuild -project Folio.xcodeproj -scheme Folio -configuration Release -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[[ -d "$APP" ]] || { echo "build failed: $APP missing" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
rm -rf "$OUT" && mkdir -p "$OUT"
ZIP="$OUT/Folio-$VERSION.zip"
DMG="$OUT/Folio-$VERSION.dmg"

echo "▶ packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Folio.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Folio $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

echo "▶ signing the update"
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  SIGNATURE=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$ZIP")
else
  SIGNATURE=$("$SPARKLE_BIN/sign_update" --account Folio "$ZIP")
fi

echo "▶ release notes and appcast"
python3 - "$ROOT/CHANGELOG.md" "$VERSION" "$BUILD" "$DOWNLOAD_BASE/Folio-$VERSION.zip" "$SIGNATURE" "$OUT" "$REPO" <<'PY'
import datetime, html, re, sys
changelog, version, build, url, signature, out, repo = sys.argv[1:]

# This version's section of CHANGELOG.md (Keep a Changelog: "## [1.2.0] - 2026-10-15").
text = open(changelog, encoding="utf-8").read()
match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
notes = match.group(1) if match else ""
notes = re.sub(r"^\[[^\]]+\]: \S+\s*$", "", notes, flags=re.M).strip()  # link definitions at the end
if not notes:
    sys.exit(f"CHANGELOG.md has no section for [{version}]")
open(f"{out}/release-notes.md", "w", encoding="utf-8").write(notes + "\n")

# Minimal Markdown → HTML for Sparkle's release-notes view: ### headings, "- " lists, `code`, **bold**.
def inline(s):
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
parts, in_list = [], False
for line in notes.splitlines():
    if line.startswith("- "):
        if not in_list: parts.append("<ul>"); in_list = True
        parts.append(f"<li>{inline(line[2:])}</li>")
        continue
    if in_list: parts.append("</ul>"); in_list = False
    if line.startswith("### "): parts.append(f"<h3>{inline(line[4:])}</h3>")
    elif line.strip(): parts.append(f"<p>{inline(line)}</p>")
if in_list: parts.append("</ul>")

date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Folio</title>
    <link>https://github.com/{repo}</link>
    <language>zh-cn</language>
    <item>
      <title>Folio {version}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/{repo}/releases</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{"".join(parts)}]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {signature} />
    </item>
  </channel>
</rss>
"""
open(f"{out}/appcast.xml", "w", encoding="utf-8").write(appcast)
PY

ls -lh "$OUT"
