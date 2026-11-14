#!/usr/bin/env bash
# 跑测试。本机 Command Line Tools 里没有 XCTest / swift-testing，
# 所以测试是一个零依赖的可执行目标（Tests/VitalsCoreTests）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift run VitalsCoreTests 2>&1 | grep -v "ld: warning" | grep -vE "^\[|^Building|^Compiling|Planning"
