#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

node --test tests/*.test.mjs
sh scripts/build.sh

required_files='index.html styles.css app.js timer-core.mjs timer-worker.js manifest.webmanifest icon.svg sw.js'
for file in $required_files; do
  test -s "dist/$file" || { printf 'Missing build artifact: %s\n' "$file" >&2; exit 1; }
done

if find dist -type f ! \( -name '*.html' -o -name '*.css' -o -name '*.js' -o -name '*.mjs' -o -name '*.webmanifest' -o -name '*.svg' \) -print | grep -q .; then
  printf 'Build contains an unsupported extension.\n' >&2
  exit 1
fi

grep -q 'lang="zh-Hant-TW"' dist/index.html
grep -q "new Worker('./timer-worker.js'" dist/app.js
grep -q "navigator.wakeLock.request('screen')" dist/app.js
grep -q "navigator.serviceWorker.register('./sw.js')" dist/app.js
grep -q "'./timer-worker.js'" dist/sw.js

printf 'Verification passed: tests, PWA shell, worker, Wake Lock, locale, and artifact extensions.\n'
