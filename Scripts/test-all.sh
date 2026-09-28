#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
bash Проверить.command
bash Scripts/test-model.sh
bash Scripts/test-quota.sh
bash Scripts/test-speech.sh
bash Scripts/test-speech-integration.sh
bash Scripts/test-project.sh
bash Scripts/test-source-revision.sh
bash Scripts/test-project-controls.sh
bash Scripts/test-instance-lock.sh
bash Scripts/test-startup.sh
bash Scripts/test-layout.sh
bash Scripts/test-runtime-preferences.sh
bash Scripts/test-runtime-settings-integration.sh
bash Scripts/test-quota-connection.sh
bash Scripts/test-request-cost.sh
bash Scripts/test-review-batch.sh
bash Scripts/test-review-budget.sh
bash Scripts/test-parallel.sh
bash Scripts/test-publication.sh
bash Scripts/test-export.sh
bash Scripts/test-video-preview.sh
ruby Tests/ReleaseTests.rb
