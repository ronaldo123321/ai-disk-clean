#!/bin/bash
# 从源码构建并安装到 ~/Applications/AI工具清理大师.app。
# 安装位置与 bundle id 固定：TCC 授权（完全磁盘访问等）绑定它们，更新后授权保留。
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$(Scripts/build-app.sh build | tail -1)
DEST="$HOME/Applications/AI工具清理大师.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "$DEST"
