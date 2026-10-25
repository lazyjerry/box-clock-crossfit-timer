#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_name=${1:-box-clock}

test -d "$project_dir/dist" || { printf 'Run npm run build before publishing.\n' >&2; exit 1; }
command -v wrangler >/dev/null 2>&1 || { printf 'wrangler is required.\n' >&2; exit 1; }

cd "$project_dir"
wrangler pages deploy dist --project-name "$project_name"
