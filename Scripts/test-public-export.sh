#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
temp="$(mktemp -d "${TMPDIR:-/tmp}/lecture-public-export-test.XXXXXX")"
trap 'rm -rf "$temp"' EXIT

python3 - "$root/PUBLIC_EXPORT_FILES.txt" <<'PY'
from pathlib import Path
import sys
entries = {line.strip() for line in Path(sys.argv[1]).read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")}
expected = {f"docs/screenshots/{language}/{theme}-{size}.png" for language in ("de", "ru", "en") for theme in ("light", "dark") for size in ("compact", "large")}
missing = sorted(expected - entries)
if missing:
    raise SystemExit("FAIL: public export allowlist omits GUI screenshot(s): " + ", ".join(missing))
print("PASS: all 12 committed-language GUI screenshots are included in public allowlist")
PY

mkdir -p "$temp/source" "$temp/output-parent"
printf 'synthetic public file\n' > "$temp/source/allowed.txt"
printf 'private local record\n' > "$temp/source/private.txt"
ruby - "$temp/source/demo.png" <<'RUBY'
require "zlib"
path = ARGV.fetch(0)
chunk = ->(kind, body) { [body.bytesize].pack("N") + kind + body + [Zlib.crc32(kind + body)].pack("N") }
png = "\x89PNG\r\n\x1a\n".b
png << chunk.call("IHDR", [1, 1, 8, 6, 0, 0, 0].pack("NNC5"))
png << chunk.call("eXIf", "synthetic capture metadata")
png << chunk.call("tEXt", "Comment\0synthetic metadata")
png << chunk.call("IDAT", Zlib::Deflate.deflate("\0\0\0\0\0"))
png << chunk.call("IEND", "")
File.binwrite(path, png)
RUBY
printf '# exact paths\nallowed.txt\ndemo.png\n' > "$temp/source/allowlist.txt"

run_export() {
  ruby "$root/Scripts/export-public.rb" --source "$temp/source" --allowlist allowlist.txt --output "$1"
}
expect_refusal() {
  local destination="$1"
  if run_export "$destination" >"$temp/stdout" 2>"$temp/stderr"; then
    echo 'FAIL: unsafe export unexpectedly succeeded' >&2
    exit 1
  fi
}

run_export "$temp/output-parent/snapshot" >/dev/null
[[ "$(git -C "$temp/output-parent/snapshot" rev-list --count HEAD)" == 1 ]]
[[ -z "$(git -C "$temp/output-parent/snapshot" status --porcelain)" ]]
[[ -f "$temp/output-parent/snapshot/allowed.txt" ]]
[[ -f "$temp/output-parent/snapshot/demo.png" ]]
[[ "$(ruby -e 'd=File.binread(ARGV.fetch(0)); puts d.include?("eXIf") || d.include?("tEXt")' "$temp/output-parent/snapshot/demo.png")" == false ]]
[[ ! -e "$temp/output-parent/snapshot/private.txt" ]]
[[ -f "$temp/output-parent/snapshot/PUBLIC_EXPORT_MANIFEST.json" ]]
[[ "$(git -C "$temp/output-parent/snapshot" config user.name)" == 'LectureTranslate Maintainers' ]]
[[ "$(git -C "$temp/output-parent/snapshot" config user.email)" == 'maintainers@lecturetranslate.invalid' ]]

printf 'missing.txt\n' > "$temp/source/allowlist.txt"
expect_refusal "$temp/output-parent/missing"
printf '../private.txt\n' > "$temp/source/allowlist.txt"
expect_refusal "$temp/output-parent/traversal"
printf 'source/allowed.txt\nsource/allowed.txt\n' > "$temp/source/allowlist.txt"
expect_refusal "$temp/output-parent/duplicate"
printf '%s%s%s\n' '/' 'Users' '/synthetic/private-lecture.srt' > "$temp/source/allowed.txt"
printf 'allowed.txt\n' > "$temp/source/allowlist.txt"
expect_refusal "$temp/output-parent/personal-path"
printf 'credential sk-%032d\n' 0 > "$temp/source/allowed.txt"
expect_refusal "$temp/output-parent/token"
printf 'synthetic public file\n' > "$temp/source/allowed.txt"
ln -s private.txt "$temp/source/linked.txt"
printf 'linked.txt\n' > "$temp/source/allowlist.txt"
expect_refusal "$temp/output-parent/symlink"
printf 'allowed.txt\n' > "$temp/source/allowlist.txt"
expect_refusal "$temp/output-parent/snapshot"
[[ ! -e "$temp/output-parent/missing" && ! -e "$temp/output-parent/traversal" && ! -e "$temp/output-parent/duplicate" ]]
[[ ! -e "$temp/output-parent/personal-path" && ! -e "$temp/output-parent/token" && ! -e "$temp/output-parent/symlink" ]]
echo 'PASS: public export allowlist, privacy checks, symlink rejection, and clean single-commit snapshot.'
