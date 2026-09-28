#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"
mode="${1:-}"
if [[ "$mode" == "--verify-only" ]]; then
  python3 - <<'PYVERIFY'
from pathlib import Path
import subprocess, struct
root = Path("docs/screenshots")
expected = [root / lang / f"{theme}-{size}.png" for lang in ("de", "ru", "en") for theme in ("light", "dark") for size in ("compact", "large")]
tracked = set(subprocess.check_output(["git", "ls-files", "--", "docs/screenshots"], text=True).splitlines())
for path in expected:
    if str(path) not in tracked or not path.is_file():
        raise SystemExit(f"Missing committed screenshot: {path}")
    raw = path.read_bytes()
    if len(raw) < 24 or raw[:8] != b"\x89PNG\r\n\x1a\n": raise SystemExit(f"Invalid PNG: {path}")
    width, height = struct.unpack(">II", raw[16:24])
    if (width, height) not in {(2424, 1752), (3104, 2024)}: raise SystemExit(f"Unexpected screenshot size {path}: {width}x{height}")
    print(f"VERIFY {path}: {width}x{height} PNG, committed")
changed = subprocess.run(["git", "diff", "--quiet", "--", "docs/screenshots"], check=False).returncode
staged = subprocess.run(["git", "diff", "--cached", "--quiet", "--", "docs/screenshots"], check=False).returncode
if changed or staged: raise SystemExit("Screenshot evidence differs from committed files")
print("GUI evidence verify-only PASS; no application launch or worktree writes")
PYVERIFY
  exit 0
fi
if [[ "$mode" != "--capture" ]]; then
  echo "Usage: $0 --verify-only | --capture --output-dir DIR | --capture --update-tracked" >&2; exit 2
fi
shift
output_dir=""
update_tracked=false
while (($#)); do
  case "$1" in
    --output-dir) output_dir="${2:?missing output directory}"; shift 2 ;;
    --update-tracked) update_tracked=true; shift ;;
    *) echo "Unknown capture option: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$output_dir" && "$update_tracked" != true ]]; then echo "Capture requires --output-dir DIR or --update-tracked" >&2; exit 2; fi
if [[ "$update_tracked" == true ]]; then output_dir="$root/docs/screenshots"; fi
mkdir -p .build/ModuleCache-v06 "$output_dir/de" "$output_dir/ru" "$output_dir/en"
package="$(mktemp -d "$root/.build/package.gui-acceptance.XXXXXX")"
app="$package/LectureTranslate.app"
state="$package/demo-state"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
trap 'if [[ -n "${app_pid:-}" ]]; then kill "$app_pid" 2>/dev/null || true; fi' EXIT
xcrun swiftc -swift-version 5 -O -D TRANSLATOR_DEMO -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 Sources/*.swift -o "$app/Contents/MacOS/LectureTranslator"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.lecturetranslator.v2.preview.demo' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LectureTranslatorDemoStateDirectory string $state" "$app/Contents/Info.plist"
cp Assets/TranslatorIcon.icns "$app/Contents/Resources/"
for locale in de ru en; do mkdir -p "$app/Contents/Resources/$locale.lproj"; cp "Resources/$locale.lproj/Localizable.strings" "$app/Contents/Resources/$locale.lproj/"; done
codesign --force --sign - --timestamp=none "$app" >/dev/null
bash Scripts/create-gui-fixture.sh "$state"
helper="$package/WindowCapture.swift"
cat > "$helper" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation
guard CommandLine.arguments.count > 1 else { exit(2) }
let expectedBundle = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
let candidates = NSWorkspace.shared.runningApplications.filter {
          $0.bundleURL?.standardizedFileURL.path == expectedBundle && $0.bundleIdentifier == "local.lecturetranslator.v2.preview.demo"
      }.sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
guard let application = candidates.first,
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
      let number = window[kCGWindowNumber as String] as? UInt32,
      let bounds = window[kCGWindowBounds as String] as? [String: Double] else { exit(2) }
print("\(application.processIdentifier) \(number) \(Int(bounds["X"] ?? 0)) \(Int(bounds["Y"] ?? 0)) \(Int(bounds["Width"] ?? 0)) \(Int(bounds["Height"] ?? 0))")
SWIFT
xcrun swiftc -module-cache-path .build/ModuleCache-v06 "$helper" -o "$package/window-capture"
for language in de ru en; do
  for theme in light dark; do
    for size in compact large; do
      width=1100; height=760
      [[ "$size" == large ]] && { width=1440; height=900; }
      if ! open -n "$app" --args --demo-language "$language" --demo-appearance "$theme" --demo-width "$width" --demo-height "$height"; then
        echo "GUI_LIMITATION: macOS Launch Services could not open the isolated demo app; no screenshot captured."
        exit 77
      fi
      capture=""
      app_pid=""
      for _ in {1..60}; do
        capture="$("$package/window-capture" "$app" 2>/dev/null || true)"
        if [[ -n "$capture" ]]; then
          read -r app_pid window_id actual_x actual_y actual_w actual_h <<<"$capture"
          if [[ "$actual_w" == "$width" && ( "$actual_h" == "$height" || ( "$height" == 760 && "$actual_h" == 764 ) ) ]]; then break; fi
        fi
        sleep 0.25
      done
      [[ -n "$capture" ]] || { echo "GUI_LIMITATION: demo window did not appear in WindowServer; no screenshot captured."; exit 77; }
      if [[ "$actual_w" != "$width" || ( "$actual_h" != "$height" && !( "$height" == 760 && "$actual_h" == 764 ) ) ]]; then
        echo "SIZE_LIMITATION language=$language theme=$theme requested=${width}x${height} actual=${actual_w}x${actual_h}"
      else
        echo "SIZE_OK language=$language theme=$theme actual=${actual_w}x${actual_h}"
      fi
      screenshot="$output_dir/$language/$theme-$size.png"
      screencapture -x -l "$window_id" "$screenshot"
      [[ -s "$screenshot" ]] || { echo "Screenshot capture failed: $screenshot" >&2; exit 1; }
      kill "$app_pid" 2>/dev/null || true
      for _ in {1..40}; do
        kill -0 "$app_pid" 2>/dev/null || break
        sleep 0.25
      done
      if kill -0 "$app_pid" 2>/dev/null; then echo "Demo process did not terminate after capture: $app_pid" >&2; exit 1; fi
      app_pid=
      sleep 1
    done
  done
done
echo "GUI screenshot matrix complete: 12 real demo-window captures in $output_dir; commit=$(git rev-parse --short HEAD); version=$(tr -d '\n' < VERSION)/build $(tr -d '\n' < BUILD_NUMBER)"
