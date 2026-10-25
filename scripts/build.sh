#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/box-clock-build.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM

mkdir -p "$stage_dir/dist"
cp "$project_dir/src/index.html" "$project_dir/src/styles.css" "$project_dir/src/app.js" "$project_dir/src/timer-core.mjs" "$project_dir/src/run-state.mjs" "$project_dir/src/device.mjs" "$project_dir/src/timer-worker.js" "$stage_dir/dist/"
cp "$project_dir/public/manifest.webmanifest" "$project_dir/public/icon.svg" "$project_dir/public/icon-maskable.svg" "$project_dir/public/apple-touch-icon.png" "$project_dir/public/jerry.png" "$project_dir/public/sw.js" "$stage_dir/dist/"

if [ -d "$project_dir/dist" ]; then
  old_dist="$project_dir/dist.previous"
  rm -rf "$old_dist"
  mv "$project_dir/dist" "$old_dist"
  mv "$stage_dir/dist" "$project_dir/dist"
  rm -rf "$old_dist"
else
  mv "$stage_dir/dist" "$project_dir/dist"
fi

printf 'Built %s\n' "$project_dir/dist"
