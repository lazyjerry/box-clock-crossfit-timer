#!/bin/sh
# 重新錄製 docs/usage/ 的操作 GIF：建置 dist、起本機伺服器、以手機尺寸的無頭 Chromium 錄影，再用 ffmpeg 轉 GIF。
# 需要 node、npm、python3、ffmpeg；Playwright 每次裝在暫存目錄，不寫進專案相依。
# 帶參數 demo（sh scripts/record-usage-gifs.sh demo）改錄 2 分鐘內、含提示音的主要流程，輸出專案根的 box-clock-demo.mp4，不進 git。
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
port=${PORT:-4174}
playwright_version=${PLAYWRIGHT_VERSION:-1.62.1}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/box-clock-gif.XXXXXX")
server_pid=''

cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

for tool in node npm python3 ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 || { printf '缺少 %s\n' "$tool" >&2; exit 1; }
done

sh "$project_dir/scripts/build.sh"

npm install --prefix "$work_dir/playwright" --no-audit --no-fund --silent "playwright@$playwright_version"
# 預設會順手刪掉其他專案留在共用快取的舊版瀏覽器，關掉這個行為
PLAYWRIGHT_SKIP_BROWSER_GC=1 "$work_dir/playwright/node_modules/.bin/playwright" install chromium

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$project_dir/dist" >/dev/null 2>&1 &
server_pid=$!
sleep 1

if [ "${1:-}" = demo ]; then
  # 只排除在本機 .git/info/exclude；.gitignore 歸 scaffold.sh 管
  exclude_file="$project_dir/.git/info/exclude"
  grep -qxF '/box-clock-demo.mp4' "$exclude_file" 2>/dev/null || printf '/box-clock-demo.mp4\n' >> "$exclude_file"
  PLAYWRIGHT_PREFIX="$work_dir/playwright" node "$project_dir/scripts/record-usage-gifs.mjs" \
    "http://127.0.0.1:$port/" "$project_dir" "$work_dir/videos" demo
  exit 0
fi

PLAYWRIGHT_PREFIX="$work_dir/playwright" node "$project_dir/scripts/record-usage-gifs.mjs" \
  "http://127.0.0.1:$port/" "$project_dir/docs/usage" "$work_dir/videos"
