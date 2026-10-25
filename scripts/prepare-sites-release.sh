#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <sites-project-id>\n' "$0" >&2
  exit 64
fi

project_id=$1
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
hosting_dir="$project_dir/.openai"
hosting_file="$hosting_dir/hosting.json"
archive_path="${TMPDIR:-/tmp}/box-clock-sites-release.tar.gz"

cd "$project_dir"
sh scripts/verify.sh

mkdir -p "$hosting_dir"
hosting_tmp=$(mktemp "$hosting_dir/hosting.json.tmp.XXXXXX")
trap 'rm -f "$hosting_tmp"' EXIT HUP INT TERM
printf '{\n  "project_id": "%s",\n  "static": { "directory": "dist" }\n}\n' "$project_id" > "$hosting_tmp"
mv "$hosting_tmp" "$hosting_file"
trap - EXIT HUP INT TERM

if [ ! -d .git ]; then
  git init -b main
fi
git add .
if ! git diff --cached --quiet; then
  git commit -m "Build CrossFit interval timer"
fi

archive_stage=$(mktemp -d "${TMPDIR:-/tmp}/box-clock-sites.XXXXXX")
trap 'rm -rf "$archive_stage"' EXIT HUP INT TERM
mkdir -p "$archive_stage/.openai" "$archive_stage/dist"
cp "$hosting_file" "$archive_stage/.openai/hosting.json"
cp -R "$project_dir/dist/." "$archive_stage/dist/"
tar -czf "$archive_path" -C "$archive_stage" .

printf 'commit_sha=%s\n' "$(git rev-parse HEAD)"
printf 'archive=%s\n' "$archive_path"
