#!/usr/bin/env bash
# 构建 Vitals.app（可双击运行的 .app bundle）。
#
#   ./scripts/build.sh          # 构建
#   ./scripts/build.sh run      # 构建 + 启动
#   ./scripts/build.sh verify   # 构建 + 启动 + 验证它在菜单栏且不进 Dock
#
# 本机只有 Xcode Command Line Tools（没有完整 Xcode），所以 .app 是手工组装的：
#   编译 → 拷贝可执行文件 → 写 Info.plist → ad-hoc 签名。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null | tail -1)"
APP="$ROOT/build/Vitals.app"

echo "▸ 编译 VitalsApp（${CONFIG}）"
swift build -c "$CONFIG" --product VitalsApp

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/VitalsApp" "$APP/Contents/MacOS/Vitals"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.vitals.app</string>
  <key>CFBundleExecutable</key><string>Vitals</string>
  <key>CFBundleName</key><string>Vitals</string>
  <key>CFBundleDisplayName</key><string>Vitals</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- 关键：LSUIElement = 不进 Dock，只在菜单栏 -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

echo "▸ ad-hoc 签名"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  （签名失败，仍可运行）"

echo "✓ 构建完成：$APP"

if [ "${1:-}" = "run" ] || [ "${1:-}" = "verify" ]; then
  echo "▸ 启动"
  open "$APP"
  sleep 2
  if [ "${1:-}" = "verify" ]; then
    echo "▸ 验证"
    # lsappinfo 里 type 应该是 UIElement（不进 Dock）
    lsappinfo find LSDisplayName=Vitals | head -1 | while read -r asid; do
      lsappinfo info -only name,type "$asid" 2>/dev/null
    done
    lsappinfo list 2>/dev/null | grep -i -A1 "Vitals" | head -6 || true
    echo "（菜单栏应出现 Vitals 图标；点它可以打开/收起悬浮窗）"
  fi
fi
