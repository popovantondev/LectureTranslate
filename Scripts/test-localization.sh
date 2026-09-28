#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"
python3 - <<'PY'
from pathlib import Path
import re

locales = ["de", "ru", "en"]
root = Path("Resources")
entries = {}
pattern = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
placeholder = re.compile(r'%(?:[0-9]+\$)?[-+#0 ]*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|h|ll|l|q|z|t|j|L)?[diuoxXfFeEgGaAcCsSp@]')
for locale in locales:
    path = root / f"{locale}.lproj" / "Localizable.strings"
    values = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("/*") or stripped.startswith("//") or stripped.endswith("*/"):
            continue
        match = pattern.match(line)
        if not match:
            raise SystemExit(f"{path}:{line_number}: malformed .strings entry")
        key, value = match.groups()
        if key in values:
            raise SystemExit(f"{path}:{line_number}: duplicate key {key}")
        if not value.strip():
            raise SystemExit(f"{path}:{line_number}: empty value for {key}")
        values[key] = value
    entries[locale] = values
if not entries["de"]:
    raise SystemExit("German catalog is empty")
reference = entries["de"]
for locale, values in entries.items():
    if set(values) != set(reference):
        missing, extra = sorted(set(reference) - set(values)), sorted(set(values) - set(reference))
        raise SystemExit(f"{locale}: key mismatch; missing={missing}, extra={extra}")
    for key, value in values.items():
        if sorted(placeholder.findall(value)) != sorted(placeholder.findall(reference[key])):
            raise SystemExit(f"{locale}: format placeholder mismatch for {key}")

# Screenshot-only launch controls must disappear from the production compile.
app_source = Path("Sources/App.swift").read_text(encoding="utf-8").splitlines()
conditional_stack = []
demo_arguments = ["--demo-language", "--demo-appearance", "--demo-width", "--demo-height"]
seen_arguments = set()
for line_number, line in enumerate(app_source, 1):
    stripped = line.strip()
    if stripped.startswith("#if "):
        conditional_stack.append(stripped[4:].strip())
    if any(argument in line for argument in demo_arguments):
        for argument in demo_arguments:
            if argument in line:
                seen_arguments.add(argument)
                if "TRANSLATOR_DEMO" not in conditional_stack:
                    raise SystemExit(f"Sources/App.swift:{line_number}: {argument} is not compile-time demo-only")
    if stripped.startswith("#endif") and conditional_stack:
        conditional_stack.pop()
if seen_arguments != set(demo_arguments):
    raise SystemExit(f"Missing demo launch controls: {sorted(set(demo_arguments) - seen_arguments)}")
build_script = Path("Scripts/build.sh").read_text(encoding="utf-8")
if "-O $($demo && echo -D TRANSLATOR_DEMO)" not in build_script:
    raise SystemExit("Production build must not define TRANSLATOR_DEMO")
print(f"Localization catalogs: {len(reference)} keys, DE/RU/EN parity and placeholders PASS")
gui_script = Path("Scripts/test-gui-acceptance.sh").read_text(encoding="utf-8")
if "--verify-only" not in gui_script or "--capture" not in gui_script or "screencapture" not in gui_script:
    raise SystemExit("GUI capture and verify-only modes must be explicit")
if "Text(journal.localizedUsageSummary(language: L10n.currentLanguage))" not in Path("Sources/App.swift").read_text(encoding="utf-8"):
    raise SystemExit("Live UI must use the localized token usage display")
print("Demo-only launch overrides excluded from production compilation: PASS")
PY
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lecture-localization.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/LocalizationTests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.lecturetranslate.localization-tests</string><key>CFBundleExecutable</key><string>LocalizationTests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/ModuleCache" Sources/Localization.swift Tests/LocalizationTests.swift -o "$app/Contents/MacOS/LocalizationTests"
"$app/Contents/MacOS/LocalizationTests"
