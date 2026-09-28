#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
mkdir -p .build/ModuleCache-v06
xcrun swiftc -swift-version 5 -D FILE_PUBLICATION_TESTS -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 Sources/FilePublication.swift Tests/FilePublicationTests.swift -o .build/FilePublicationTests
.build/FilePublicationTests
