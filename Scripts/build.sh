#!/bin/bash
set -euo pipefail
translator_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$translator_root"
version="$(tr -d '\r\n' < VERSION)"
build="$(tr -d '\r\n' < BUILD_NUMBER)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || exit 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)" == "$version" ]] || exit 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)" == "$build" ]] || exit 2
product_name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' Info.plist)"
[[ "$product_name" == "LectureTranslate" ]] || { echo 'Unexpected product name in Info.plist'; exit 2; }
mkdir -p .build/ModuleCache-v06 dist
mkdir .build/build.lockdir || { echo 'Другая сборка уже работает. Проверьте блокировку.'; exit 2; }
trap 'rmdir "$translator_root/.build/build.lockdir"' EXIT
preview=false
demo=false
if [[ "${1:-}" == --preview ]]; then preview=true; elif [[ "${1:-}" == --demo ]]; then demo=true; elif [[ $# -ne 0 ]]; then exit 2; fi
if ! $preview && ! $demo && [[ -e "dist/v$version" ]]; then echo "Выпуск v$version уже существует. Не перезаписываю."; exit 2; fi
stage="$(mktemp -d "$translator_root/.build/package.XXXXXX")"
app="$stage/$product_name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -O $($demo && echo -D TRANSLATOR_DEMO) -target arm64-apple-macosx15.0 \
  -module-cache-path .build/ModuleCache-v06 Sources/*.swift -o "$app/Contents/MacOS/LectureTranslator"
cp Info.plist "$app/Contents/Info.plist"
if $preview; then
  # Preview tools may relaunch the app without inherited environment variables.
  # Bake isolation into this generated bundle, never into the production plist.
  preview_id="local.lecturetranslator.v2.preview"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $preview_id" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LectureTranslatorPreviewStateDirectoryName string LectureTranslator2-Preview' "$app/Contents/Info.plist"
fi
if $demo; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.lecturetranslator.v2.preview.demo' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LectureTranslatorPreviewStateDirectoryName string LectureTranslator2-Demo' "$app/Contents/Info.plist"
fi
cp Assets/TranslatorIcon.icns Assets/TranslatorIcon.png "$app/Contents/Resources/"
for locale in de ru en; do
  resource="Resources/$locale.lproj/Localizable.strings"
  [[ -s "$resource" ]] || { echo "Missing localization resource: $resource"; exit 2; }
  mkdir -p "$app/Contents/Resources/$locale.lproj"
  cp "$resource" "$app/Contents/Resources/$locale.lproj/Localizable.strings"
done
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
ruby "$translator_root/Scripts/build-manifest.rb" "$stage" "$version" "$build"
if $preview || $demo; then echo "$( $demo && echo 'Демо-сборка' || echo 'Пробная сборка' ): $app"
else
  mv "$stage" "$translator_root/dist/v$version"
  echo "Новый выпуск: $translator_root/dist/v$version/$product_name.app"
fi
