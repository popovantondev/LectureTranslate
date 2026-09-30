#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
mkdir -p .build/ModuleCache-v06
test_bundle="$(mktemp -d "$translator_root/.build/runtime-preferences-test.XXXXXX")"
trap 'rm -rf "$test_bundle"' EXIT
app="$test_bundle/RuntimePreferencesTests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.lecturetranslate.runtime-preferences-tests</string><key>CFBundleExecutable</key><string>RuntimePreferencesTests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -D TRANSLATOR_MODEL_TESTS -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 Sources/*.swift \
  Tests/RuntimePreferencesTests.swift -o "$app/Contents/MacOS/RuntimePreferencesTests"
"$app/Contents/MacOS/RuntimePreferencesTests"
