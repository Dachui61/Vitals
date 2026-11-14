Type: task
Status: resolved
Blocked by: none

# 用 root 验证 SMC 协议能否取到 CPU 温度

## Question

票 20 把 `AppleSMCKeysEndpoint` 的协议完全还原了，但取数被 `kIOReturnNotPrivileged` 挡住，而授权检查发生在查键之前——**是调用者身份被拒，不是通道不存在**。root 会不会被放行，只有实际跑一次才知道。

本会话沙箱内 `sudo` 不可用（`/usr/bin/sudo` 报 "Operation not permitted"），所以这是一件**必须由人在普通 Terminal 里做**的事。做完后，票 04 才能在"特权组件"与"只有热压力四档"之间做出有依据的选择。

## 需要执行的动作（照抄即可，约 2 分钟）

在普通 Terminal（不是本会话）里：

```bash
cd /Users/liuyu/Documents/deepseek-harness/default-workspace

# 1) 编译探针（若已编译可跳过）
swiftc -O -target arm64-apple-macosx27.0 \
  -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
  scratch/t20_smcproto.swift -o scratch/t20_smcproto -framework IOKit

# 2) 无特权基线（预期：NotPrivileged）
scratch/t20_smcproto A TC0P

# 3) 关键验证：同样一条命令加 sudo（预期：NotPrivileged → OK，并返回 168 字节含温度）
sudo scratch/t20_smcproto A TC0P

# 4) 候选键位扫描（哪些键真的有温度；预期能看到几个 30–60 之间的浮点数）
for k in TC0P TC0D TC0H TC0F TCAD TG0P Th0H TA0P Tp09 Tp0T; do
  printf '== %s: ' "$k"; sudo scratch/t20_smcproto A "$k"
done

# 5) 负载下是否会变（验证它确实是活的温度而不是常量）
sudo scratch/t20_smcproto A TC0P
yes > /dev/null &   # 制造 CPU 负载，约 20 秒
sleep 20; sudo scratch/t20_smcproto A TC0P; kill %1
```

把 **第 2–5 步的完整输出**贴回来（或存成 `/tmp/smc-root.txt` 后告诉我路径）。

## 判据

- 第 3 步从 `NotPrivileged` 变成 `OK` 且返回里有温度浮点数 → **特权组件路线成立**，票 14 改为用这套还原出的协议读温度（不走 powermetrics），票 04 的候选 (b) 被选中。
- 第 3 步仍是 `NotPrivileged` → **特权也不放行**，数值 °C 在本机彻底无解；票 04 选 (c)（热压力四档 + 明确标注不可用），并把它记为对 v1 需求的让步。
- 第 3 步变成别的错误（如 BadArgument / Unsupported）→ 记录原始错误码，可能说明还有协议细节没还原（例如命令字节随机型变化），需要再开一轮逆向。
- 第 4 步若某些键返回合理温度、某些返回 nil/错误 → 把可用键位固化下来，作为特权组件的**白名单键**（安全边界用）。

## 备注

- 探针源码：`scratch/t20_smcproto.swift`（也在分支 `research/other-temperature-channels` 的 `research/probes/` 下）。
- 若第 4 步全都不通但第 3 步 OK，说明键名或命令字节需要再试（例如 `Tp09`/`Tp0T` 这类 plist 风格键，或 thermalmonitord 的 `PMU tcal` 路线）——把那部分输出也一并贴回，交给下一轮逆向。

## Answer

**本票作废，被票 01 的发现取代。** 不需要 root 验证了：`/usr/lib/libSMC.dylib`（macOS 27 的经典 SMC 继任者）**无特权**就能读到数值温度，实测 Tp05/Tp09 随 CPU 负载明显上升（见票 01 的答案）。特权通道（票 20 还原的 168 字节 IOKit 协议）因此不再是温度路线的必要条件。

移交给新票 23 的只有一点：**键语义识别**（哪个键才是 CPU die）。其中"root 下读同一批键"只能证明权限不是变量、不能证明键语义，优先级低，因此不必做。

原探针与报告保留在分支 `research/other-temperature-channels`（`research/probes/t20_smcproto.swift`），将来若需要 root 交叉验证仍可取用。
