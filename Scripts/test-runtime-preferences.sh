#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
mkdir -p .build/ModuleCache-v06
runtime_stub="$(mktemp /tmp/lecture-translator-runtime-stub.XXXXXX.swift)"
test_bundle="$(mktemp -d "$translator_root/.build/runtime-preferences-test.XXXXXX")"
trap 'rm -f "$runtime_stub"; rm -rf "$test_bundle"' EXIT
cat > "$runtime_stub" <<'SWIFT'
enum TranslatorRuntime { static var isDemoBuild: Bool { false } }
SWIFT
app="$test_bundle/RuntimePreferencesTests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.lecturetranslate.runtime-preferences-tests</string><key>CFBundleExecutable</key><string>RuntimePreferencesTests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 \
  Sources/FilePublication.swift \
  Sources/Core.swift Sources/Quota.swift Sources/Localization.swift Sources/Translation.swift Sources/ReviewBatch.swift Sources/ReviewBudget.swift Sources/Memory.swift Sources/Recovery.swift \
  Sources/Listening.swift Sources/SpeechText.swift Sources/InstanceLock.swift Sources/RuntimePreferences.swift \
  "$runtime_stub" Tests/RuntimePreferencesTests.swift -o "$app/Contents/MacOS/RuntimePreferencesTests"
"$app/Contents/MacOS/RuntimePreferencesTests"
