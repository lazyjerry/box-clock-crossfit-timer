#!/bin/sh
# Render public/icon-maskable.svg into a 180x180 opaque PNG with headless Chrome,
# write it as base64 into the apple-touch-icon heredoc of scaffold.sh, then rerun scaffold.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scaffold="$project_dir/scripts/scaffold.sh"
source_svg="$project_dir/public/icon-maskable.svg"
marker='base64 --decode > "$project_dir/public/apple-touch-icon.png" <<'"'"'EOF'"'"''

chrome=${CHROME:-}
if [ -z "$chrome" ]; then
  for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" google-chrome chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
      chrome=$candidate
      break
    fi
  done
fi
[ -n "$chrome" ] || { printf 'Chrome not found; set CHROME to its executable path.\n' >&2; exit 1; }
test -s "$source_svg" || { printf 'Missing %s; run sh scripts/scaffold.sh first.\n' "$source_svg" >&2; exit 1; }
grep -qF "$marker" "$scaffold" || { printf 'apple-touch-icon heredoc not found in scaffold.sh.\n' >&2; exit 1; }

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/box-clock-icon.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

cp "$source_svg" "$work_dir/icon.svg"
cat > "$work_dir/render.html" <<'EOF'
<!doctype html>
<html><body style="margin:0;background:#171e34"><img src="icon.svg" width="180" height="180" style="display:block"></body></html>
EOF

"$chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --allow-file-access-from-files \
  --virtual-time-budget=2000 --window-size=180,180 --screenshot="$work_dir/icon.png" "file://$work_dir/render.html" >/dev/null 2>&1
test -s "$work_dir/icon.png" || { printf 'Chrome did not produce a screenshot.\n' >&2; exit 1; }

base64 < "$work_dir/icon.png" | tr -d '\n' | fold -w 76 > "$work_dir/icon.b64"
printf '\n' >> "$work_dir/icon.b64"

awk -v marker="$marker" -v data="$work_dir/icon.b64" '
  skipping && $0 == "EOF" { skipping = 0 }
  skipping { next }
  { print }
  $0 == marker { while ((getline line < data) > 0) print line; skipping = 1 }
' "$scaffold" > "$work_dir/scaffold.sh"
cat "$work_dir/scaffold.sh" > "$scaffold"

sh "$scaffold"
printf 'Rendered public/apple-touch-icon.png from public/icon-maskable.svg\n'
