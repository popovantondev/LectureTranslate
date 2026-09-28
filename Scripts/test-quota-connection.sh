#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
mkdir -p .build/ModuleCache-quota-connection
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-quota-connection \
  Sources/Core.swift Sources/SpeechText.swift Sources/Quota.swift Sources/QuotaConnection.swift \
  Tests/QuotaConnectionTests.swift -o .build/QuotaConnectionTests
.build/QuotaConnectionTests
