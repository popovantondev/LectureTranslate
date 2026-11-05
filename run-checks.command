#!/bin/zsh
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$translator_root/.build/ModuleCache-v06"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path "$translator_root/.build/ModuleCache-v06" \
  "$translator_root/Sources/SpeechText.swift" \
  "$translator_root/Sources/FilePublication.swift" \
  "$translator_root/Sources/InstanceLock.swift" \
  "$translator_root/Tests/TranslatorRuntimeStub.swift" \
  "$translator_root/Sources/Core.swift" "$translator_root/Sources/Quota.swift" "$translator_root/Sources/Localization.swift" "$translator_root/Sources/Translation.swift" "$translator_root/Sources/ReviewBatch.swift" "$translator_root/Sources/ReviewBudget.swift" "$translator_root/Sources/Memory.swift" "$translator_root/Sources/Recovery.swift" "$translator_root/Sources/Listening.swift" "$translator_root/Tests/CoreTests.swift" \
  -o "$translator_root/.build/CoreTests"
"$translator_root/.build/CoreTests"
