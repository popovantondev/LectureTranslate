# Build and local tests

## Requirements

macOS 15 or later, Apple Silicon, Apple Command Line Tools (Swift), Bash, and Ruby. Translation and review require the locally installed Codex CLI signed in with ChatGPT. The local build and test suite makes no model calls. FFmpeg/ffprobe are optional and used only by selected media features.

## Known state of this checkout

`VERSION`, `BUILD_NUMBER`, and `Info.plist` are aligned at **3.5.1 / build 16**. The previous saved release is 3.4.3 / build 13; older release directories remain unchanged.

The full offline suite passed 2,473 local checks, including 64 video-preview and 14 release validations. The 12-window demo matrix (3 languages × 2 themes × 2 sizes) was captured. Additional isolated scenarios checked timing diagnostics, settings, review notes, export with a warning, replacement with backup, project saving, and queue persistence after relaunch. No user lectures were used.

## Local commands

From the project directory:

```sh
bash Scripts/test-all.sh
bash Scripts/build.sh --preview
```

Tests use synthetic data and isolated temporary state. They do not start translation, read the account, or modify user data.

- `bash Scripts/test-all.sh` — connected local test suite.
- `bash Scripts/test-model.sh` — pause and resume with an isolated test queue, without model calls.
- `bash Scripts/test-quota.sh` — CLI path, error diagnostics, timeout, and cancellation using local fixtures.
- `bash Scripts/test-speech.sh` — local checks for suspicious numbers, units, abbreviations, and characters.
- `bash Scripts/test-project.sh` — save, integrity check, and open `.lectureproject`.
- `bash Scripts/test-instance-lock.sh` — instance locking and owner discovery.
- `ruby Tests/ReleaseTests.rb` — release and archive checks without a model.
- `bash Scripts/build.sh --preview` — isolated preview app under `.build`; it does not overwrite a release directory.

Do not manually modify existing `dist/vX.Y.Z` or `releases/vX.Y.Z` directories. Release builds refuse to overwrite an existing destination.

## macOS notice

The published ZIP is not Developer ID-signed or Apple-notarized; macOS may warn on first launch. A local ad-hoc signature is not a substitute for Developer ID signing or notarization.

For details, see the English [project overview](README.md). The internal verification log is not part of this public documentation set.
