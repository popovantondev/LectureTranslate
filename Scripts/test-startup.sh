#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
python3 - <<'PY'
from pathlib import Path
import plistlib
info = plistlib.loads(Path("Info.plist").read_bytes())
assert info["CFBundleName"] == "LectureTranslate"
assert info["CFBundleDisplayName"] == "LectureTranslate"
assert info["CFBundleIdentifier"] == "local.lecturetranslator.v2"
app = Path("Sources/App.swift").read_text()
assert 'CommandGroup(replacing: .appSettings)' in app
assert 'keyboardShortcut(",")' in app and 'keyboardShortcut("o")' in app and 'keyboardShortcut("s")' in app
assert '.textEditing' not in app, "native macOS text editing responder commands must remain installed"
assert 'CommandMenu(L10n.current("menu.appearance"))' in app
assert 'CommandGroup(replacing: .help)' in app
print("Startup identity, menu, and native shortcut source checks PASS")
PY
mkdir -p .build/ModuleCache-v06
xcrun swiftc -swift-version 5 -D TRANSLATOR_MODEL_TESTS -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 Sources/*.swift Tests/StartupTests.swift -o .build/StartupTests
.build/StartupTests
xcrun swiftc -swift-version 5 -D TRANSLATOR_MODEL_TESTS -D TRANSLATOR_DEMO -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 Sources/*.swift Tests/StartupTests.swift -o .build/StartupTests-Demo
.build/StartupTests-Demo
