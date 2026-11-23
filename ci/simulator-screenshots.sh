#!/usr/bin/env bash
# CI only: builds the app for the iOS Simulator (engine stub), runs it on an iPad
# simulator with demo content and prints downscaled screenshots as base64 into the log.
set -euo pipefail
cd "$(dirname "$0")/.."
touch .engine-stub

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
if swift build --package-path ci/AppBuilder --triple arm64-apple-ios17.0-simulator --sdk "$SDK" 2>&1 | tail -20; then
  BIN=$(swift build --package-path ci/AppBuilder --triple arm64-apple-ios17.0-simulator --sdk "$SDK" --show-bin-path)/NoteAppExec
fi
if [ ! -f "${BIN:-/nonexistent}" ]; then
  echo "swift build failed; trying xcodebuild"
  (cd ci/AppBuilder && xcodebuild build -scheme NoteAppExec -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath "$PWD/dd" CODE_SIGNING_ALLOWED=NO > xcb.log 2>&1 || (grep -E "error:" xcb.log | head -40; exit 1))
  BIN=$(find ci/AppBuilder/dd/Build/Products -name NoteAppExec -type f | head -1)
fi
python3 ci/make_app.py "$BIN" build/NoteApp.app Resources/Info.plist

TYPE=$(xcrun simctl list devicetypes -j | python3 -c "
import json,sys
t=json.load(sys.stdin)['devicetypes']
pick=[d['identifier'] for d in t if 'iPad Pro 11' in d['name']] or [d['identifier'] for d in t if 'iPad' in d['name']]
print(pick[-1])")
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "
import json,sys
r=[x['identifier'] for x in json.load(sys.stdin)['runtimes'] if x.get('platform')=='iOS' and x.get('isAvailable')]
print(r[-1])")
UDID=$(xcrun simctl create NoteCI "$TYPE" "$RUNTIME")
echo "device $TYPE $RUNTIME $UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl install "$UDID" build/NoteApp.app

status=0
for screen in library editor pdf connect settings; do
  xcrun simctl terminate "$UDID" com.lemon7679.note > /dev/null 2>&1 || true
  xcrun simctl launch "$UDID" com.lemon7679.note -NoteDemoScreen "$screen"
  sleep 9
  if ! xcrun simctl spawn "$UDID" launchctl list | grep -q "com.lemon7679.note"; then
    echo "APP NOT RUNNING after opening '$screen' (crash?)"
    status=1
  fi
  xcrun simctl io "$UDID" screenshot "shot-$screen.png" > /dev/null
  sips -Z 1000 -s format jpeg -s formatOptions 60 "shot-$screen.png" --out "shot-$screen.jpg" > /dev/null
  echo "@@SHOT $screen"
  base64 -i "shot-$screen.jpg" -b 120
  echo "@@END"
done

echo "== crash reports"
for f in $(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i "NoteApp" || true); do
  echo "-- $f"; head -c 6000 ~/Library/Logs/DiagnosticReports/"$f"; echo
  status=1
done
echo "== app log"
xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'process == "NoteApp"' 2>/dev/null \
  | grep -viE "BackBoard|UIKitCore.*hover" | tail -60 || true
exit $status
