#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
mkdir -p .build/ModuleCache-v06
cat > .build/ReviewRuntimeStub.swift <<'SWIFT'
enum TranslatorRuntime { static let isDemoBuild = false }
SWIFT
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 \
  Sources/FilePublication.swift \
  Sources/InstanceLock.swift Sources/Core.swift Sources/Quota.swift Sources/Localization.swift Sources/Translation.swift \
  Sources/Memory.swift Sources/Recovery.swift Sources/Listening.swift Sources/SpeechText.swift \
  .build/ReviewRuntimeStub.swift Sources/ReviewBatch.swift Sources/ReviewBudget.swift Tests/ReviewBudgetTests.swift -o .build/ReviewBudgetTests
.build/ReviewBudgetTests
