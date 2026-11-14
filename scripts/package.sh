#!/usr/bin/env bash
# 打包 Vitals.pkg —— 双击即可安装，**不需要管理员密码**。
#
# 安装位置全部在用户域：
#   ~/Applications/Vitals.app
#   ~/Library/LaunchAgents/local.vitals.app.plist   （开机自启）
#
# 用法：./scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "▸ 编译 app"
./scripts/build.sh >/dev/null

echo "▸ 组装用户域暂存目录"
mkdir -p "$STAGE/home/Applications"
mkdir -p "$STAGE/home/Library/LaunchAgents"
cp -R "build/Vitals.app" "$STAGE/home/Applications/"

LABEL="local.vitals.app"
cat > "$STAGE/home/Library/LaunchAgents/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/Applications/Vitals.app/Contents/MacOS/Vitals</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

echo "▸ 打包"
pkgbuild --root "$STAGE/home" \
         --identifier "$LABEL" \
         --version "0.1.0" \
         --install-location "$HOME" \
         "$STAGE/component.pkg" >/dev/null

cat > "$STAGE/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Vitals</title>
    <organization>local</organization>
    <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
    <options customize="never" require-scripts="false"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="13.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="local.vitals.app"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="local.vitals.app" visible="false">
        <pkg-ref id="local.vitals.app"/>
    </choice>
    <pkg-ref id="local.vitals.app" version="0.1.0" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild --distribution "$STAGE/distribution.xml" \
              --package-path "$STAGE" \
              "build/Vitals.pkg" >/dev/null

echo "✓ 打包完成：build/Vitals.pkg"
echo "  双击安装 → ~/Applications/Vitals.app + 开机自启（用户域，不需要管理员密码）"
echo "  卸载：./scripts/uninstall.sh"
