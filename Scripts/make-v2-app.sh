#!/bin/bash
# 构建并安装清理大师V2.app。
# 固定安装位置（~/Applications/清理大师V2.app）：TCC 授权（废纸篓访问/完全磁盘访问）绑定路径，
# 路径随时间戳变化会导致授权失效。
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$HOME/Applications/清理大师V2.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiskCleanerApp "$APP/Contents/MacOS/"
# RulePack.bundledData 在 Contents/Resources 中查找资源包；release 构建不回退到 SwiftPM 开发目录，缺了会报「找不到内置规则」。
cp -R .build/release/DiskCleaner_CleanerCore.bundle "$APP/Contents/Resources/"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.ronaldo123321.diskcleaner' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName 清理大师V2' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 清理大师V2' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.11.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 11' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
