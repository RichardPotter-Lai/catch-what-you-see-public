#!/bin/bash
# Download and install the published macOS app without replacing an existing app.
set -euo pipefail

catch_version='0.1.1'
catch_release='https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/download/v0.1.1'
catch_name='Catch what you see.app'
catch_dir='/Applications'
catch_open=1
if [ ! -w "$catch_dir" ]; then catch_dir="$HOME/Applications"; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --destination)
      [ "$#" -ge 2 ] || { echo '--destination needs a directory.' >&2; exit 1; }
      catch_dir="$2"; shift 2 ;;
    --no-open) catch_open=0; shift ;;
    -h|--help)
      echo 'Usage: bash install-macos.sh [--destination DIRECTORY] [--no-open]'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo 'Catch what you see 需要 macOS 14 或更新版本。' >&2; exit 1; }
catch_os=$(sw_vers -productVersion)
[ "${catch_os%%.*}" -ge 14 ] || { echo '需要 macOS 14 或更新版本。' >&2; exit 1; }
mkdir -p "$catch_dir"
catch_dir=$(cd "$catch_dir" && pwd -P)
catch_target="$catch_dir/$catch_name"
if [ -e "$catch_target" ] || [ -L "$catch_target" ]; then
  echo "已存在 ${catch_target}；脚本不会覆盖。升级方法见仓库 docs/INSTALL.md。" >&2
  exit 1
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
hdiutil attach -readonly -nobrowse -mountpoint "$catch_mount" "$catch_work/$catch_dmg"
catch_mounted=1
catch_source="$catch_mount/$catch_name"
codesign --verify --deep --strict "$catch_source"
catch_bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$catch_source/Contents/Info.plist")
catch_actual_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$catch_source/Contents/Info.plist")
[ "$catch_bundle" = local.catchwhatyousee.mac ] && [ "$catch_actual_version" = "$catch_version" ]
catch_stage=$(mktemp -d "$catch_dir/.catch-install.XXXXXX")
ditto "$catch_source" "$catch_stage/$catch_name"
# mv -n leaves the staged app in place if another installer created the target.
mv -n "$catch_stage/$catch_name" "$catch_dir/"
[ ! -e "$catch_stage/$catch_name" ] || { echo '目标已存在，未覆盖。' >&2; exit 1; }
echo "已安装到 $catch_target"
echo '首次打开和辅助功能授权请按 macOS 提示完成；脚本不会更改系统权限。'
if [ "$catch_open" -eq 1 ]; then open "$catch_target"; fi
