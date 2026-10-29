#!/bin/bash
# make_icon.sh —— 重新生成 AppIcon.icns
#
# 图标是代码画的，不是手绘位图：改设计只改 gen_icon.swift 里的参数，然后跑这个脚本。
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
swiftc -O gen_icon.swift -o "$TMP/gen_icon"
"$TMP/gen_icon" "$TMP/AppIcon.iconset"

# 保存一张 1024 预览方便比对
cp "$TMP/AppIcon.iconset/icon_512x512@2x.png" "预览-1024.png"

iconutil -c icns "$TMP/AppIcon.iconset" -o ../AppIcon.icns
echo "==> ../AppIcon.icns"
ls -lh ../AppIcon.icns
rm -rf "$TMP"
