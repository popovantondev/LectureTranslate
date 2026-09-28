#!/bin/bash
set -euo pipefail
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--ffmpeg" ) ]]; then
  echo 'Usage: bash Scripts/test-video-preview.sh [--ffmpeg]' >&2
  exit 64
fi
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
mkdir -p .build/ModuleCache-v06
xcrun swiftc -swift-version 5 -D TRANSLATOR_MODEL_TESTS -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 Sources/*.swift Tests/VideoPreviewTests.swift -o .build/VideoPreviewTests
.build/VideoPreviewTests "$@"
