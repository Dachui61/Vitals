Type: task
Status: resolved
Blocked by: none

# 修复：悬浮窗拖不动

## Question

用户反馈"不能拖动悬浮窗的位置"。这是票 12 的真实缺陷：实现里从没让窗口真的能拖。

## Answer

**已修复并有自动化验证**（`VITALS_SELFTEST=1` 让应用自己合成一次拖动，位移精确等于预期）。

**根因**：`NSHostingView` 铺满整个窗口，会吃掉所有鼠标事件，所以 `isMovableByWindowBackground` 对 SwiftUI 内容**完全无效**——窗口没有任何可拖的表面。原型里画的那个"≡"抓手只是装饰，从没接过拖拽逻辑。

**修法**：在 app 层给 HostingView 做子类 `DraggableHostingView`，在 `mouseDown` 里接管：

- 按下时记录窗口原点与抓取点（视图坐标）；
- `mouseDragged` 里用**事件自身的坐标**算位移并 `setFrameOrigin`；
- 两处例外留给 SwiftUI 自己的控件：右上角关闭按钮、右下角缩放握把（按窗口尺寸算出这两块矩形，点到它们就走 `super.mouseDown`）。

**为什么用事件坐标而不是 `NSEvent.mouseLocation`**：全局光标位置对合成事件不变化，自测没法复现；而且事件坐标是相对窗口的，抓取点会一直贴在光标下，行为与系统标题栏一致（真实拖动时也正确 —— 窗口移动后事件坐标随之变化，但推导下来窗口仍然精确跟随光标）。

**验证**：
- 应用内自测：`VITALS_SELFTEST=1` → 合成 mouseDown/mouseDragged/mouseUp → 窗口从 (24, 205) 移到 (204, 85)，位移与预期一致 → 打印「✅ 拖动生效」并退出码 0。
- 已并入 `scripts/acceptance-check.sh`（验收项 D3），现在自动项 **24 条全过**。

**行为变化（需要告知用户）**：面板主体任意位置拖动 = 移动窗口；面板里的滚动因此要用**滚轮/触控板双指**（拖动不再用于滚动）。内容区的滚动只是小窗口下的溢出兜底。
