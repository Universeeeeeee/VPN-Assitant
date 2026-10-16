#!/bin/bash
# =============================================================================
# 一键安装: 安装检测引擎 + 构建并启动 App
#
#   用法:
#     ./install.sh                 安装并启动
#     ./install.sh --login-item    同时加入登录项 (开机自启)
#
#   可用环境变量:
#     BIN_DIR   引擎安装位置, 默认 ~/.local/bin
#     APP_OUT   App 产物路径, 默认 ~/Applications/VPN节点助手.app
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
APP_NAME="VPN节点助手"
APP="${APP_OUT:-$HOME/Applications/$APP_NAME.app}"

command -v swiftc >/dev/null 2>&1 || {
  echo "❌ 需要 Xcode Command Line Tools (swiftc)。请先运行: xcode-select --install"
  exit 1
}
command -v jq >/dev/null 2>&1 || echo "⚠️  未找到 jq, 引擎会退回 sed 解析 JSON (建议: brew install jq)"

echo "▶ 安装检测引擎"
mkdir -p "$BIN_DIR"
install -m 755 "$ROOT/engine/vpn-node-guard.sh" "$BIN_DIR/vpn-node-guard.sh"
echo "  $BIN_DIR/vpn-node-guard.sh"

echo "▶ 构建 App"
APP_OUT="$APP" "$ROOT/app/build.sh"

echo "▶ 启动"
open "$APP"
sleep 2
if pgrep -f VPNNodeHelper >/dev/null; then
  echo "  ✅ 已启动"
else
  echo "  ⚠️  没有检测到进程, 请手动打开 $APP"
fi

if [ "${1:-}" = "--login-item" ]; then
  echo "▶ 加入登录项 (开机自启)"
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP\", hidden:true}" \
    >/dev/null 2>&1 && echo "  ✅ 已加入" || echo "  ⚠️  失败 (需要在系统设置里授予自动化权限, 或手动到「登录项」里添加)"
fi

cat <<EOF

✅ 安装完成
   · 菜单栏会出现「节点正常 / 节点不稳定 / 节点故障」
   · 首次检测大约需要 15~30 秒
   · 检测间隔 30 分钟, 修改 app/App.swift 里的 intervalMinutes 后重新构建

   常用命令:
     $BIN_DIR/vpn-node-guard.sh --status     # 逐个列出组内所有节点
     $BIN_DIR/vpn-node-guard.sh --json       # JSON 报告 (App 用的就是它)
     $BIN_DIR/vpn-node-guard.sh --dry-run    # 走一遍决策流程但不切任何东西
     tail -f ~/Library/Logs/VPNNodeHelper.log

   卸载:
     osascript -e 'tell application "System Events" to delete login item "$APP_NAME"'
     pkill -f VPNNodeHelper; rm -rf "$APP"
EOF
