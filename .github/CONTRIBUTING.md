# Contributing

Thank you for helping improve LectureTranslate.

## Before opening an issue or pull request

- Check existing issues and choose the [German](../docs/de/BUILD.md), [Russian](../docs/ru/BUILD.md), or [English](../docs/en/BUILD.md) build guide.
- Describe observed behavior and expected behavior with a small synthetic example.
- Keep changes limited to LectureTranslate. Changes to separate speech or video assembly programs are out of scope.
- Preserve subtitle meaning, numbers, units, negation, cue IDs, and exact timecodes.
- Do not include lecture files, `.lectureproject` archives, local logs, credentials, private application state, personal paths, or private email addresses. Replace them with synthetic material.

## Local checks

On macOS 15 or later with Apple Command Line Tools, run:

```sh
bash Scripts/test-all.sh
bash Scripts/build.sh --preview
ruby Tests/ReleaseTests.rb
```

These checks are local and do not require Codex sign-in, account access, model requests, or a paid API. Do not repeat completed translations to test a code change.

## Pull requests

Explain the user-visible change, privacy impact, checks run, and any known limitations. Use screenshots only when they are necessary, and make them with synthetic data. Do not claim Developer ID signing or Apple notarization: neither is part of this project workflow.
