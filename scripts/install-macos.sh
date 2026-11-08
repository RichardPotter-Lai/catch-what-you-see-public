#!/bin/bash
# 从 GitHub Releases 安装（或升级）Catch what you see。
#
# 一行安装（终端或 Agent 均可执行）：
#   curl -fsSL https://raw.githubusercontent.com/RichardPotter-Lai/catch-what-you-see-public/main/scripts/install-macos.sh | bash
# 升级已安装的版本：
#   curl -fsSL https://raw.githubusercontent.com/RichardPotter-Lai/catch-what-you-see-public/main/scripts/install-macos.sh | bash -s -- --upgrade
#
# 用 curl 下载的安装包不带浏览器的“隔离”标记，所以安装后直接打开，
# 不会被 Gatekeeper 拦下要求“仍要打开”。脚本仍会核对 SHA-256、签名、
# 包标识和版本，任何一项不符就停止。
set -euo pipefail

catch_repo='RichardPotter-Lai/catch-what-you-see-public'
catch_name='Catch what you see.app'
catch_bundle_id='local.catchwhatyousee.mac'
catch_version=''
catch_dir='/Applications'
catch_open=1
catch_upgrade=0
if [ ! -w "$catch_dir" ]; then catch_dir="$HOME/Applications"; fi

usage() {
  cat <<'USAGE'
用法: install-macos.sh [选项]
  --upgrade              已安装时替换旧版（旧版移到废纸篓，资料库不受影响）
  --version X.Y.Z        安装指定版本（默认最新 Release）
  --destination DIR      安装目录（默认 /Applications，不可写时 ~/Applications）
  --no-open              安装后不自动打开
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --destination)
      [ "$#" -ge 2 ] || { echo '--destination 需要一个目录。' >&2; exit 1; }
      catch_dir="$2"; shift 2 ;;
    --version)
      [ "$#" -ge 2 ] || { echo '--version 需要版本号，例如 0.1.2。' >&2; exit 1; }
      catch_version="${2#v}"; shift 2 ;;
    --upgrade) catch_upgrade=1; shift ;;
    --no-open) catch_open=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知选项: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo 'Catch what you see 需要 macOS 14 或更新版本。' >&2; exit 1; }
catch_os=$(sw_vers -productVersion)
[ "${catch_os%%.*}" -ge 14 ] || { echo "需要 macOS 14 或更新版本（当前 $catch_os）。" >&2; exit 1; }

if [ -z "$catch_version" ]; then
  catch_latest=$(curl --fail --silent --show-error --location --proto '=https' --output /dev/null \
    --write-out '%{url_effective}' "https://github.com/$catch_repo/releases/latest")
  catch_version="${catch_latest##*/v}"
  case "$catch_version" in
    [0-9]*.[0-9]*) ;;
    *) echo "无法确定最新版本（$catch_latest），可用 --version 指定。" >&2; exit 1 ;;
  esac
fi
catch_release="https://github.com/$catch_repo/releases/download/v$catch_version"
echo "准备安装 Catch what you see $catch_version"

mkdir -p "$catch_dir"
catch_dir=$(cd "$catch_dir" && pwd -P)
catch_target="$catch_dir/$catch_name"
if [ -e "$catch_target" ] || [ -L "$catch_target" ]; then
  if [ "$catch_upgrade" -ne 1 ]; then
    catch_existing=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$catch_target/Contents/Info.plist" 2>/dev/null || echo '未知')
    echo "已安装 ${catch_target}（版本 $catch_existing）。如需升级，加上 --upgrade 重新运行。" >&2
    exit 1
  fi
  catch_existing_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$catch_target/Contents/Info.plist" 2>/dev/null || true)
  [ "$catch_existing_id" = "$catch_bundle_id" ] || { echo "$catch_target 不是 Catch what you see，未替换。" >&2; exit 1; }
fi

catch_work=$(mktemp -d "${TMPDIR:-/tmp}/catch-install.XXXXXX")
catch_mount="$catch_work/mount"
catch_mounted=0
catch_stage=''
cleanup() {
  if [ -n "$catch_stage" ]; then rm -rf "$catch_stage"; fi
  if [ "$catch_mounted" -eq 1 ]; then
    if ! hdiutil detach "$catch_mount" >/dev/null 2>&1; then
      echo "请手动推出安装映像：$catch_mount" >&2
      return
    fi
  fi
  rm -rf "$catch_work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

catch_dmg="Catch-what-you-see-${catch_version}-universal.dmg"
curl --fail --location --retry 2 --proto '=https' "$catch_release/$catch_dmg" --output "$catch_work/$catch_dmg"
curl --fail --location --retry 2 --proto '=https' "$catch_release/SHA256SUMS.txt" --output "$catch_work/SHA256SUMS.txt"
(cd "$catch_work" && shasum -a 256 -c SHA256SUMS.txt)
mkdir "$catch_mount"
hdiutil attach -readonly -nobrowse -mountpoint "$catch_mount" "$catch_work/$catch_dmg" >/dev/null
catch_mounted=1
catch_source="$catch_mount/$catch_name"
codesign --verify --deep --strict "$catch_source"
catch_bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$catch_source/Contents/Info.plist")
catch_actual_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$catch_source/Contents/Info.plist")
[ "$catch_bundle" = "$catch_bundle_id" ] && [ "$catch_actual_version" = "$catch_version" ] \
  || { echo "安装包标识或版本不符（$catch_bundle $catch_actual_version）。" >&2; exit 1; }

catch_stage=$(mktemp -d "$catch_dir/.catch-install.XXXXXX")
ditto "$catch_source" "$catch_stage/$catch_name"
# 本地复制不应带隔离标记；保险起见只清除这个 App 自己的标记，不改动系统 Gatekeeper 设置。
xattr -dr com.apple.quarantine "$catch_stage/$catch_name" 2>/dev/null || true

if [ -e "$catch_target" ]; then
  # 正常退出正在运行的旧版，再把旧版移到废纸篓（可恢复）。
  if pgrep -f "$catch_target/Contents/MacOS/" >/dev/null 2>&1; then
    osascript -e "tell application id \"$catch_bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      pgrep -f "$catch_target/Contents/MacOS/" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if pgrep -f "$catch_target/Contents/MacOS/" >/dev/null 2>&1; then
      echo '旧版仍在运行，请先从菜单栏退出 Catch 再重试。' >&2; exit 1
    fi
  fi
  catch_trash="$HOME/.Trash/Catch what you see $(date +%Y%m%d-%H%M%S).app"
  mv "$catch_target" "$catch_trash"
  echo "旧版已移到废纸篓：$catch_trash"
fi
# mv -n 不会覆盖期间被别的安装程序创建的目标。
mv -n "$catch_stage/$catch_name" "$catch_dir/"
[ ! -e "$catch_stage/$catch_name" ] || { echo '目标已存在，未覆盖。' >&2; exit 1; }
echo "已安装 Catch what you see $catch_version 到 $catch_target"
echo '首次打开后，应用会弹窗引导开启“辅助功能”权限（Option+C 收藏文字需要）。'
echo '这一步需要你本人在系统设置里打开开关并验证密码或 Touch ID，脚本和 Agent 都无法代办。'
if [ "$catch_upgrade" -eq 1 ]; then
  echo '升级后如果开关已开但仍提示无权限：在辅助功能列表里删除旧的 Catch 条目，再重新添加。'
fi
if [ "$catch_open" -eq 1 ]; then open "$catch_target"; fi
