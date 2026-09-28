#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
mkdir -p .build/ModuleCache-v06
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 \
  Sources/FilePublication.swift \
  Sources/InstanceLock.swift \
  Tests/TranslatorRuntimeStub.swift \
  Sources/Core.swift Sources/Quota.swift Sources/Localization.swift Sources/Translation.swift Sources/ReviewBatch.swift Sources/ReviewBudget.swift Sources/Memory.swift \
  Sources/Recovery.swift Sources/SpeechText.swift Sources/ProjectArchive.swift Tests/ProjectTests.swift -o .build/ProjectTests
.build/ProjectTests
