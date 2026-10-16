#!/bin/bash
# =============================================================================
# 构建 「VPN节点助手」 菜单栏 App
#
#   产物: ${APP_OUT:-$HOME/Applications/VPN节点助手.app}
#   依赖: Xcode Command Line Tools (swiftc), macOS 13+
# =============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
APP="${APP_OUT:-$HOME/Applications/VPN节点助手.app}"
EXEC_NAME="VPNNodeHelper"

# 默认打包仓库里的引擎; 也可以用 ENGINE_PATH 指定别的副本
ENGINE="${ENGINE_PATH:-$ROOT/engine/vpn-node-guard.sh}"
if [ ! -f "$ENGINE" ]; then
  echo "  ⚠️  找不到 $ENGINE, 回退到 ~/.local/bin/vpn-node-guard.sh"
  ENGINE="$HOME/.local/bin/vpn-node-guard.sh"
fi
[ -f "$ENGINE" ] || { echo "❌ 找不到检测引擎脚本, 无法继续"; exit 1; }

echo "▶ 清理旧产物"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ 编译 Swift 源码"
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -o "$APP/Contents/MacOS/$EXEC_NAME" \
  "$SRC/App.swift"

echo "▶ 组装 App bundle"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$ENGINE" "$APP/Contents/Resources/vpn-node-guard.sh"
chmod +x "$APP/Contents/Resources/vpn-node-guard.sh"

echo "▶ Ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/  /' || true

echo "▶ 校验"
plutil -lint "$APP/Contents/Info.plist" >/dev/null && echo "  Info.plist OK"
[ -x "$APP/Contents/MacOS/$EXEC_NAME" ] && echo "  可执行文件 OK"
[ -x "$APP/Contents/Resources/vpn-node-guard.sh" ] && echo "  内置检测脚本 OK"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist" \
  | sed 's/^/  显示名称: /'
echo "✅ 构建完成: $APP"
