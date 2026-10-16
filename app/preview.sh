#!/bin/bash
# =============================================================================
# 离屏渲染界面预览 —— 不需要点菜单栏, 直接把「不稳定」状态下的界面渲染成 PNG
#
#   用法: ./preview.sh [输出路径]     默认 /tmp/panel_preview.png
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/tmp/panel_preview.png}"

PREVIEW_OUT="$OUT" swiftc -D DEMO -swift-version 5 -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -o "$DIR/.preview-bin" \
  "$DIR/App.swift" "$DIR/Preview.swift"

PREVIEW_OUT="$OUT" "$DIR/.preview-bin"
