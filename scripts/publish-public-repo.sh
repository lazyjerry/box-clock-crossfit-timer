#!/bin/sh
set -eu

repository=${1:?Usage: scripts/publish-public-repo.sh <owner/repository>}
branch=$(git branch --show-current)

test -n "$branch" || { printf 'Cannot publish a detached HEAD.\n' >&2; exit 1; }
if git remote get-url origin >/dev/null 2>&1; then
  printf 'Remote origin already exists: %s\n' "$(git remote get-url origin)" >&2
  exit 1
fi
if gh repo view "$repository" --json nameWithOwner >/dev/null 2>&1; then
  printf 'GitHub repository already exists: %s\n' "$repository" >&2
  exit 1
fi

gh repo create "$repository" --public --source=. --remote=origin --push

local_sha=$(git rev-parse HEAD)
remote_sha=$(git ls-remote origin "refs/heads/$branch" | awk '{print $1}')
test "$local_sha" = "$remote_sha" || { printf 'Push verification failed.\n' >&2; exit 1; }

printf 'Published %s at %s\n' "$repository" "$local_sha"
