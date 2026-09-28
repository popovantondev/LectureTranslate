#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
[[ "$#" -eq 1 ]] || { echo 'Specify isolated preview-state directory' >&2; exit 64; }
mkdir -p .build/ModuleCache-v06
xcrun swiftc -swift-version 5 -D TRANSLATOR_MODEL_TESTS -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 Sources/*.swift Tests/GUIFixture.swift -o .build/GUIFixture
.build/GUIFixture "$1"
