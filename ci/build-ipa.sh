#!/usr/bin/env bash
# Builds an unsigned NoteApp IPA (Release, arm64 iPhoneOS) on macOS with Xcode.
# Needs the real engine: note-core checked out next to note-ipad (../note-core).
# Install the result with `xtool install NoteApp-<version>.ipa` (signs with your Apple ID).
#
# usage: ci/build-ipa.sh [version] [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
OUT="${2:-build}"
[ -f ../note-core/Package.swift ] || { echo "error: ../note-core not found" >&2; exit 1; }
rm -f .engine-stub

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
swift build --package-path ci/AppBuilder -c release --triple arm64-apple-ios17.0 --sdk "$SDK"
BIN="$(swift build --package-path ci/AppBuilder -c release --triple arm64-apple-ios17.0 --sdk "$SDK" --show-bin-path)/NoteAppExec"

# The real engine must be linked in (the CI stub has no C symbols).
nm -U "$BIN" > "$BIN.symbols"
grep "_ink_editor_create" "$BIN.symbols" > /dev/null || { echo "error: InkEngine not linked" >&2; exit 1; }

mkdir -p "$OUT"
rm -rf "$OUT/Payload"
python3 ci/make_app.py "$BIN" "$OUT/Payload/NoteApp.app" Resources/Info.plist --device \
  --icon Resources/AppIcon.png --version "$VERSION"
IPA="$OUT/NoteApp-$VERSION.ipa"
rm -f "$IPA"
(cd "$OUT" && zip -qry "NoteApp-$VERSION.ipa" Payload)
echo "ipa: $IPA"
ls -l "$IPA"
lipo -info "$OUT/Payload/NoteApp.app/NoteApp"
otool -l "$OUT/Payload/NoteApp.app/NoteApp" > "$OUT/load-commands.txt"
grep -A4 LC_BUILD_VERSION "$OUT/load-commands.txt" | head -5   # platform 2 = iOS
otool -L "$OUT/Payload/NoteApp.app/NoteApp" | head -20
shasum -a 256 "$IPA"
