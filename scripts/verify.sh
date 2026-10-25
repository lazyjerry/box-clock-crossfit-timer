#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

node --test tests/*.test.mjs
sh scripts/build.sh

required_files='index.html styles.css app.js timer-core.mjs run-state.mjs device.mjs timer-worker.js manifest.webmanifest icon.svg icon-maskable.svg apple-touch-icon.png jerry.png sw.js'
for file in $required_files; do
  test -s "dist/$file" || { printf 'Missing build artifact: %s\n' "$file" >&2; exit 1; }
done

if find dist -type f ! \( -name '*.html' -o -name '*.css' -o -name '*.js' -o -name '*.mjs' -o -name '*.webmanifest' -o -name '*.svg' -o -name '*.png' \) -print | grep -q .; then
  printf 'Build contains an unsupported extension.\n' >&2
  exit 1
fi

grep -q 'lang="zh-Hant-TW"' dist/index.html
grep -q "new Worker('./timer-worker.js'" dist/app.js
grep -q "navigator.wakeLock.request('screen')" dist/app.js
grep -q "navigator.serviceWorker.register('./sw.js')" dist/app.js
grep -q "'./timer-worker.js'" dist/sw.js
grep -q 'id="test-sound-button"' dist/index.html
grep -q 'id="sound-volume"' dist/index.html
grep -q 'min="20" max="100" step="5" value="50"' dist/index.html
grep -q '50%：符合裝置音量' dist/index.html
grep -q 'id="sound-enabled-label"' dist/index.html
grep -q 'function playSoundPreview' dist/app.js
grep -q 'soundVolume' dist/app.js
grep -q 'function soundOutputGain' dist/app.js
grep -q 'createDynamicsCompressor' dist/app.js
grep -q 'function updateSoundToggleLabel' dist/app.js
grep -q 'networkFirst' dist/sw.js
grep -q "box-clock-v30" dist/sw.js
! grep -q 'id="sound-button"' dist/index.html
! grep -q 'id="fullscreen-button"' dist/index.html
! grep -q "#sound-button" dist/app.js
! grep -q "#fullscreen-button" dist/app.js
grep -q 'value="fortime" checked' dist/index.html
grep -q 'id="mode-help-dialog"' dist/index.html
grep -q 'function openModeHelp' dist/app.js
grep -q "localStorage.setItem(STORAGE_KEY" dist/app.js
grep -q 'function loadSettings' dist/app.js
grep -q 'id="reset-button"' dist/index.html
grep -q 'function resetTimer' dist/app.js
grep -q 'body.timer-running .timer-view' dist/styles.css
grep -q "'./run-state.mjs'" dist/sw.js
grep -q 'function pauseForBackground' dist/app.js
grep -q 'restoreSavedRun();' dist/app.js
grep -q "addEventListener('click', finishWorkout)" dist/app.js
grep -q 'id="share-button"' dist/index.html
grep -q 'id="warning-dialog"' dist/index.html
grep -q 'id="battery-warning-text"' dist/index.html
grep -q 'navigator.getBattery()' dist/app.js
grep -q "'./device.mjs'" dist/sw.js
grep -q 'function renderShareImage' dist/app.js
grep -q 'function startWallClock' dist/app.js
grep -q '"src": "./icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any" }' dist/manifest.webmanifest
grep -q '"src": "./icon-maskable.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "maskable" }' dist/manifest.webmanifest
! grep -q '<rect width="512" height="512" rx=' dist/icon-maskable.svg
grep -q 'rel="apple-touch-icon" href="./apple-touch-icon.png"' dist/index.html
grep -q "'./apple-touch-icon.png'" dist/sw.js
head -c 26 dist/apple-touch-icon.png | od -An -tx1 | tr -d ' \n' | grep -q '^89504e470d0a1a0a0000000d49484452000000b4000000b40802$'
grep -q 'id="mode-guide-dialog"' dist/index.html
grep -q 'href="https://github.com/lazyjerry/box-clock-crossfit-timer"' dist/index.html
grep -q "'./jerry.png'" dist/sw.js
grep -q 'id="install-dialog"' dist/index.html
grep -q 'data-install-panel="ios"' dist/index.html
grep -q "matchMedia('(display-mode: standalone)')" dist/app.js
grep -q 'navigator.standalone === true' dist/app.js

printf 'Verification passed: tests, PWA shell, worker, Wake Lock, normalized 50 percent device-volume audio, locale, and artifact extensions.\n'
