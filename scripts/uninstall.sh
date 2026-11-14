#!/usr/bin/env bash
# 卸载 Vitals：移除 app、开机自启项与缓存。
#
#   ./scripts/uninstall.sh          # 干跑（只打印要做什么）
#   ./scripts/uninstall.sh --apply  # 真的删
set -euo pipefail

LABEL="local.vitals.app"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

APP="$HOME/Applications/Vitals.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/Vitals"

echo "▸ 停止并注销开机自启"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "  已 bootout $LABEL" || echo "  （未在运行，跳过）"

echo "▸ 删除文件"
for target in "$APP" "$PLIST" "$SUPPORT"; do
  if [ -e "$target" ]; then
    if [ "$APPLY" = "1" ]; then
      rm -rf "$target"
      echo "  已删除 $target"
    else
      echo "  [干跑] 将删除 $target"
    fi
  else
    echo "  （不存在，跳过）$target"
  fi
done

if [ "$APPLY" = "0" ]; then
  echo
  echo "这是干跑。确认后执行：./scripts/uninstall.sh --apply"
fi
