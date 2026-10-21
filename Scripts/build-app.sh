#!/bin/bash
# 编译通用版（Apple 芯片 + Intel）的 AI工具清理大师.app，本地临时签名。
# 命令行工具 dclean 一并放在 Contents/MacOS 里。
# 用法：Scripts/build-app.sh [输出目录]，默认 build/；最后一行输出 .app 路径。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.12.0
BUILD_NUMBER=12
OUT="${1:-build}"

swift build -c release --arch arm64 --arch x86_64 >&2
PRODUCTS=.build/apple/Products/Release
APP="$OUT/AI工具清理大师.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/DiskCleanerApp" "$PRODUCTS/dclean" "$APP/Contents/MacOS/"
# RulePack.bundledData 在 Contents/Resources 中查找资源包；dclean 经符号链接调用时也会按真实位置找到这里。
cp -R "$PRODUCTS/DiskCleaner_CleanerCore.bundle" "$APP/Contents/Resources/"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
# 附带的可执行文件要先单独签名，再签整个应用
codesign --force --sign - "$APP/Contents/MacOS/dclean" >&2
codesign --force --sign - "$APP" >&2
codesign --verify --deep --strict "$APP" >&2
echo "$APP"
