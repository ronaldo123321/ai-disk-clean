#!/bin/bash
# 生成发行包 dist/AI-Disk-Clean-macos.zip（含 .app，命令行工具 dclean 在包内），并输出 SHA-256。
# 文件名不带版本号，这样 releases/latest/download/AI-Disk-Clean-macos.zip 始终指向最新版（install.sh 依赖它）。
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf dist
mkdir -p dist
APP=$(Scripts/build-app.sh dist | tail -1)
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" dist/AI-Disk-Clean-macos.zip
rm -rf "$APP"
shasum -a 256 dist/AI-Disk-Clean-macos.zip | tee dist/AI-Disk-Clean-macos.zip.sha256
