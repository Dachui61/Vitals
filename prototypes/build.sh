#!/usr/bin/env bash
# 编译并打包票 05 的悬浮窗原型。产出 prototypes/VitalsPrototype.app。
#
#   ./prototypes/build.sh          # 编译 + 打包
#   ./prototypes/build.sh run      # 编译 + 打包 + 启动
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/prototypes/VitalsPrototype.app"
CACHE="$ROOT/.modulecache"

mkdir -p "$CACHE" "$APP/Contents/MacOS"

swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
  -module-cache-path "$CACHE" -Xcc -fmodules-cache-path="$CACHE" \
  "$ROOT/prototypes/VitalsPanelPrototype.swift" \
  -o "$APP/Contents/MacOS/VitalsPrototype" \
  -framework SwiftUI -framework AppKit -framework Foundation

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.vitals.prototype</string>
  <key>CFBundleExecutable</key><string>VitalsPrototype</string>
  <key>CFBundleName</key><string>Vitals 悬浮窗原型</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"

if [ "${1:-}" = "run" ]; then
  open "$APP"
  echo "launched (原型窗口应出现在屏幕左上角)"
fi
