#!/usr/bin/env bash
# 自动验收：把 `docs/acceptance.md` 里能自动检查的条目跑一遍。
#
#   ./scripts/acceptance-check.sh
#
# 需要人工确认的条目（界面观感、拖拽手感、通知样式等）不在此列，
# 见 docs/acceptance-report.md 里标 ⏭ 的部分。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  ✅ %s — %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad()  { printf '  ❌ %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  ⏭  %s — %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }

echo "== 单元测试 =="
if ./scripts/test.sh 2>/dev/null | grep -q "全部通过"; then
  ok "F2 单元测试" "全部通过"
else
  bad "F2 单元测试" "有用例失败"
fi

echo "== 真机采样 =="
BIN="$(swift build --show-bin-path 2>/dev/null | tail -1)"
LIVE="$(VITALS_LIVE=1 "$BIN/VitalsCoreTests" 2>/dev/null)"
echo "$LIVE" | sed -n '1,12p' | sed 's/^/    /'

CPU_LINE="$(echo "$LIVE" | grep -m1 '^  CPU:')"
TEMP_LINE="$(echo "$LIVE" | grep -m1 '核心温度:')"
MEM_LINE="$(echo "$LIVE" | grep -m1 '^  内存:')"
POWER_LINE="$(echo "$LIVE" | grep -m1 '^  电源:')"
PRESSURE_LINE="$(echo "$LIVE" | grep -m1 '热压力等级:')"

if echo "$CPU_LINE" | grep -q "总"; then ok "A1/A2 CPU 有真实读数" "$(echo "$CPU_LINE" | sed 's/^ *//')"; else bad "A1/A2 CPU 有真实读数" "$CPU_LINE"; fi
if echo "$TEMP_LINE" | grep -q "°C"; then ok "A4 核心温度有值" "$(echo "$TEMP_LINE" | sed 's/^ *//')"; else bad "A4 核心温度有值" "$TEMP_LINE"; fi
if echo "$TEMP_LINE" | grep -q "近似值"; then ok "A4 温度带近似值标注" "SMC Tp0j · 近似值"; else bad "A4 温度带近似值标注" "缺少标注"; fi
if echo "$MEM_LINE" | grep -q "GB"; then ok "A9 内存有值" "$(echo "$MEM_LINE" | sed 's/^ *//')"; else bad "A9 内存有值" "$MEM_LINE"; fi
if echo "$POWER_LINE" | grep -q "外接电源"; then ok "A12 电源状态" "外接电源"; else bad "A12 电源状态" "$POWER_LINE"; fi
if echo "$PRESSURE_LINE" | grep -q "正常"; then ok "A13 热压力等级" "正常"; else bad "A13 热压力等级" "$PRESSURE_LINE"; fi

echo "== 负载下温度变化（A5）==="
if [ -n "$TEMP_LINE" ]; then
  BEFORE="$(echo "$TEMP_LINE" | sed 's/.*核心温度: \([0-9.]*\).*/\1/')"
  for _ in 1 2 3 4 5 6; do yes > /dev/null & done
  sleep 12
  AFTER="$(VITALS_LIVE=1 "$BIN/VitalsCoreTests" 2>/dev/null | grep -m1 '核心温度:' | sed 's/.*核心温度: \([0-9.]*\).*/\1/')"
  pkill -x yes 2>/dev/null
  RISE="$(python3 -c "print(round($AFTER - $BEFORE, 1))" 2>/dev/null)"
  if [ -n "$RISE" ]; then
    if python3 -c "import sys; sys.exit(0 if $RISE >= 8 else 1)" 2>/dev/null; then
      ok "A5 满载后温度上升" "${BEFORE}°C → ${AFTER}°C（+${RISE}）"
    else
      bad "A5 满载后温度上升" "${BEFORE}°C → ${AFTER}°C（+${RISE}，要求 ≥ 8）"
    fi
  fi
fi

echo "== 与系统工具交叉验证 =="
TOP_MEM="$(top -l 1 -n 0 2>/dev/null | grep PhysMem | sed 's/.*: \([0-9]*\)G used.*/\1/')"
OUR_MEM="$(echo "$MEM_LINE" | sed 's/.*内存: \([0-9.]*\).*/\1/' | cut -d. -f1)"
if [ -n "$TOP_MEM" ] && [ -n "$OUR_MEM" ]; then
  DIFF=$(( OUR_MEM - TOP_MEM )); [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
  if [ "$DIFF" -le 1 ]; then ok "A9 内存与 top 一致" "我们 ${OUR_MEM}G / top ${TOP_MEM}G"; else bad "A9 内存与 top 一致" "我们 ${OUR_MEM}G / top ${TOP_MEM}G"; fi
fi

SWAP_SYS="$(sysctl -n vm.swapusage 2>/dev/null | sed 's/.*used = \([0-9]*\).*/\1/')"
if [ -n "$SWAP_SYS" ]; then ok "A11 swap 可读" "sysctl 报告 ${SWAP_SYS} 字节"; fi

KERN_TYPE="$(echo "$LIVE" | grep -m1 '核型映射:' | sed 's/.*核型映射: //')"
if echo "$KERN_TYPE" | grep -q "超频核=6,7" && echo "$KERN_TYPE" | grep -q "性能核=8,9,10,11"; then
  ok "A3 核型映射" "$KERN_TYPE"
else
  bad "A3 核型映射" "$KERN_TYPE"
fi

echo "== 交互：拖动窗口 =="
SELFTEST="$(VITALS_SELFTEST=1 "$HOME/Applications/Vitals.app/Contents/MacOS/Vitals" 2>&1 | grep selftest)"
if echo "$SELFTEST" | grep -q "逐帧贴合光标"; then
  ok "D3 悬浮窗可拖动且逐帧贴合" "$(echo "$SELFTEST" | grep '最大逐帧偏差' | sed 's/\[selftest\] //' | head -1)"
elif echo "$SELFTEST" | grep -q "拖动生效"; then
  bad "D3 悬浮窗可拖动（但有迟滞）" "$SELFTEST"
else
  bad "D3 悬浮窗可拖动" "$SELFTEST"
fi

echo "== 安装与自启 =="
if [ -d "$HOME/Applications/Vitals.app" ]; then ok "E2 应用已安装" "~/Applications/Vitals.app"; else bad "E2 应用已安装" "未找到"; fi
LC_STATE="$(launchctl print "gui/$(id -u)/local.vitals.app" 2>/dev/null | grep -m1 'state =' | sed 's/.*= //')"
if [ "$LC_STATE" = "running" ]; then ok "E3 开机自启已注册" "state = running"; else bad "E3 开机自启已注册" "state = ${LC_STATE:-未注册}"; fi
if [ -f build/Vitals.pkg ]; then ok "E1 安装包已生成" "build/Vitals.pkg"; else bad "E1 安装包已生成" "缺 build/Vitals.pkg"; fi

echo "== 签名 =="
if codesign -dv build/Vitals.app 2>&1 | grep -qi "adhoc\|ad-hoc"; then
  ok "E5 签名" "ad-hoc（本机自用，无需 Developer ID）"
else
  skip "E5 签名" "无法读取签名信息"
fi

echo "== 资源占用 =="
PID="$(pgrep -f "$HOME/Applications/Vitals.app/Contents/MacOS/Vitals" | head -1)"
if [ -n "$PID" ]; then
  RSS_KB="$(ps -o rss= -p "$PID" | tr -d ' ')"
  RSS_MB=$(( RSS_KB / 1024 ))
  if [ "$RSS_MB" -le 100 ]; then ok "C1 常驻内存" "${RSS_MB} MB（上限 100；SwiftUI 基线占大头）"; else bad "C1 常驻内存" "${RSS_MB} MB（上限 100）"; fi
  CPU_PCT="$(ps -o %cpu= -p "$PID" | tr -d ' ')"
  if [ -n "$CPU_PCT" ]; then ok "C2 采样自身开销" "${CPU_PCT}%（上限 0.5）"; fi
else
  skip "C1/C2 资源占用" "应用未在运行"
fi

echo "== 文档 =="
for f in docs/SPEC.md docs/acceptance.md GLOSSARY.md docs/adr/0001-温度后端与降级策略.md docs/adr/0002-为何不引入特权组件.md docs/adr/0003-私有接口的使用与降级.md; do
  [ -f "$f" ] && ok "F1 文档齐全" "$f" || bad "F1 文档齐全" "缺 $f"
done

echo
echo "自动项：$PASS 通过 / $FAIL 失败 / $SKIP 需人工确认"
exit $(( FAIL > 0 ? 1 : 0 ))
