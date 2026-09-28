#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"
python3 - <<'PY'
from pathlib import Path
import re

# Regression coverage is deliberately explicit. The source-driven audit below scans
# all Swift files; this set determines which findings are currently release-blocking.
covered = {
    "Sources/ExportControls.swift",
    "Sources/ListeningView.swift",
    "Sources/ProjectControls.swift",
    "Sources/RuntimeControls.swift",
    "Sources/Startup.swift",
    "Sources/TermsView.swift",
    "Sources/VideoPreviewView.swift",
    "Sources/App.swift",
    "Sources/ParallelTranslation.swift",
    "Sources/RuntimePreferences.swift",
}
visible = re.compile(r'\b(?:Text|Label|Button|Toggle|Picker|Menu|CommandMenu|ContentUnavailableView|NSAlert|NSOpenPanel|NSButton|workflowStep)\s*\(|\.messageText\s*=|\.informativeText\s*=|\.title\s*=|accessibilityLabel\s*\(|@Published\s+var\s+banner\s*=')
cyrillic = re.compile(r'[\u0400-\u052f]')
literal = re.compile(r'"((?:\\.|[^"\\])*)"')
failures = []
outside_candidates = []
files = sorted(Path("Sources").rglob("*.swift"))
inventoried = 0
for path in files:
    filename = path.as_posix()
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not visible.search(line):
            continue
        inventoried += 1
        # Interpolated diagnostics can contain arbitrary OS/user text; only flag
        # literal Russian copy, never values supplied by the app or its data.
        for match in literal.finditer(line):
            value = match.group(1)
            if cyrillic.search(value):
                finding = f"{filename}:{number}: visible Cyrillic literal {value!r}"
                (failures if filename in covered else outside_candidates).append(finding)
if failures:
    raise SystemExit("Unlocalized product UI literals in covered surfaces:\n" + "\n".join(failures))
print(f"Localization source inventory: {len(files)} Swift files, {inventoried} visible-copy source lines scanned")
print(f"Regression coverage: {len(covered)} scoped localization source files; no unlocalized Russian literals")
print(f"Outside regression coverage: {len(outside_candidates)} visible Cyrillic literal candidates")
for finding in outside_candidates:
    print("AUDIT " + finding)
print("Outside candidates require source review; user/model content and stable machine values are data, not authored UI.")
PY
