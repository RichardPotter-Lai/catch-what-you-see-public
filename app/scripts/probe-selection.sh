#!/bin/bash
# 手动实验：只检查固定合成文字，绝不输出选区内容或来源 URL。
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE="${1:-com.apple.TextEdit}"
printf '请在 5 秒内切换到目标 App，选中固定合成文字，并保持前台。\n'
sleep 5
exec "build/Catch what you see.app/Contents/MacOS/CatchWhatYouSee" --probe-synthetic-selection "$BUNDLE"
