#!/bin/bash
# 一键安装或更新 AI工具清理大师：
#   curl -fsSL https://raw.githubusercontent.com/ronaldo123321/ai-disk-clean/main/Scripts/install.sh | bash
# 用 curl 下载的文件不带隔离标记，打开时不会被「无法验证开发者」拦下。
set -euo pipefail
URL="${AIDC_ZIP_URL:-https://github.com/ronaldo123321/ai-disk-clean/releases/latest/download/AI-Disk-Clean-macos.zip}"
DEST="$HOME/Applications/AI工具清理大师.app"

if pgrep -xq DiskCleanerApp; then
  echo "AI工具清理大师正在运行，请先从菜单栏退出后再安装。" >&2
  exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "正在下载最新版…"
curl -fL --progress-bar "$URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mv "$TMP/AI工具清理大师.app" "$DEST"
echo "已安装到 $DEST"
echo "如需命令行工具 dclean：sudo ln -sf \"$DEST/Contents/MacOS/dclean\" /usr/local/bin/dclean"
open "$DEST"
