#!/bin/bash
# 合成测试库只在本次新建的临时目录；退出后保留，便于核查。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cwsy-development.XXXXXX")
mkdir -p "$ROOT/Library/Notes" "$ROOT/Library/Attachments"
printf '合成测试库：%s\n' "$ROOT/Library"
exec "build/Catch what you see.app/Contents/MacOS/CatchWhatYouSee" --development --library "$ROOT/Library" "$@"
