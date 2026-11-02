---
title: 区域截图原位编辑实施计划
status: active
last_updated: 2026-10-28
related_spec: ../specs/2026-10-28-inline-capture-design.md
---

# 区域截图原位编辑 Implementation Plan

> **For agentic workers:** 使用 executing-plans 顺序执行；仅在用户选择后使用 subagent-driven-development。

**Goal:** 区域选取后在同一面板、原选区位置直接标注，不弹出居中编辑窗口。

**Architecture:** Selector 持有隐藏面板直至抓图完成，控制器接收其所有权并复用 ImageEditor。图像矩形与窗口工具占位区分开，原图标注模型和导出不变。

**Tech Stack:** Swift 6、AppKit、SwiftUI、现有 screencapture -R；Apple Silicon / macOS 27。

**Spec:** [原位编辑设计](../specs/2026-10-28-inline-capture-design.md)。

## Global Constraints

- 本计划仅改变区域截图；窗口/全屏模式保持现状。
- 不新增冻结屏幕、窗口识别或全局键盘监听，不替换图片渲染引擎。
- 主线程操作 AppKit，后台解码；保留 20 MiB/40MP 上限、超时、无覆盖写入和取消清理。
- 同一个 NSPanel 是验收条件，不能只创建一个同位置新窗口。
- 不默认提交、推送、重新安装；已有工作区保持不变。

## Task 1：选区面板所有权转交

**Files:** App/Screenshot/ScreenshotRegionSelector.swift、AppTests/ScreenshotTests.swift。

**Interfaces:** 保留 init(completion:) 的 CGRect? 回调，新增 private(set) selectedFrame: CGRect?（AppKit 全局点）；新增 takeEditorPanel() -> NSPanel? 转交已完成选区的窗口。cancel() 仍可随时释放未转交面板。

- [x] **1. 增加红灯测试。** 在现有 regionDragUsesEventCoordinatesWhenPointerHasAlreadyMoved 测试的 mouseUp 后加入：

~~~swift
let transferred = try #require(selector.takeEditorPanel())
#expect(transferred === window)
#expect(!transferred.isVisible)
#expect(selector.selectedFrame != nil)
#expect(selector.takeEditorPanel() == nil)
selector.cancel()
#expect(transferred.contentView != nil)
transferred.contentView = nil
transferred.close()
~~~

保持现有屏幕坐标和 Control 按键断言；另加“mouseUp 后 cancel 未转交面板”的路径，确认窗口关闭并 contentView == nil。用 NSApp.windows 查对象不能只凭标题判断是否新建。

- [x] **2. 运行红灯。**

~~~bash
bash scripts/build-engine.sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests
~~~

- [x] **3. 让选区完成隐藏而不销毁。** show 的闭包先从现有 captureRect 得到 integral 截图矩形，再反算 selectedFrame，确保图片抓取边界与面板使用同一四舍五入结果：

~~~swift
self?.selectedFrame = capture.map {
    CGRect(x: $0.minX, y: primary.frame.maxY - $0.maxY,
           width: $0.width, height: $0.height)
}
~~~

capture 为当前闭包中调用 Self.captureRect 返回的 CGRect?；用该值调用 finish。finish 的完成回调仍置 nil、超时仍取消；rect 非 nil 仅 orderOut，rect nil 则关闭。将关闭逻辑提取为以下 private 方法，cancel 必须在回调已经消耗时也调用它：

~~~swift
private func closePanel() {
    window?.orderOut(nil)
    window?.contentView = nil
    window?.close()
    window = nil
}
func takeEditorPanel() -> NSPanel? {
    guard completion == nil, selectedFrame != nil else { return nil }
    let panel = window
    window = nil
    return panel
}
~~~

cancel 先调用 finish(nil)，再 closePanel；完成回调 nil 时 finish 直接返回，closePanel 仍保证释放。不要把 selectedFrame 清理绑定到 takeEditorPanel，调用方需先后读取它。

- [x] **4. 重跑定向测试。** 原取消一次、控制器 stop 取消等待中的 continuation、反向拖动及负坐标转换全部保留。停止路径不能触发已完成 continuation 第二次。

## Task 2：同窗原位编辑及小选区布局

**Files:** App/Screenshot/ScreenshotController.swift、App/Screenshot/ImageEditor.swift、AppTests/ScreenshotTests.swift、AppTests/ImageEditorTests.swift。

**Interfaces:** edit 改为 edit(_ image: NSImage, in existingWindow: NSWindow? = nil, selectionFrame: CGRect? = nil)；ImageEditor 新增 canvasFrame: CGRect? = nil 参数（SwiftUI 左上原点，局部点坐标），保留 window/pasteboard/onPin/onClose。新增 nonisolated static inlineEditorFrame(selection:visibleFrame:) -> CGRect。

- [x] **1. 写布局与窗口身份测试。** 新布局 helper 测试：

~~~swift
@Test func inlineEditorKeepsSelectionInsideWithoutRecentering() {
    let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    let selected = CGRect(x: -1300, y: 200, width: 400, height: 300)
    #expect(ScreenshotController.inlineEditorFrame(selection: selected, visibleFrame: screen) == selected)
    let tiny = CGRect(x: -12, y: 8, width: 8, height: 6)
    let frame = ScreenshotController.inlineEditorFrame(selection: tiny, visibleFrame: screen)
    #expect(frame.contains(tiny))
    #expect(frame.width >= 240 && frame.height >= 120)
    #expect(screen.contains(frame))
}
~~~

在现有 NSImage 测试样本基础上创建一个 PinnedImagePanel，记录 windowNumber，调用 edit(image, in: panel, selectionFrame: selected)；断言 number 不变、panel.frame 等于 helper 结果、contentView 非 nil，关闭后 contentView == nil。记录调用前后 NSApp.windows，不能出现第二个编辑窗口。以明确的 #require 构造 800×600 像素图及 400×300 点矩形，确认导出仍为 800×600。

- [x] **2. 先跑上述失败测试，然后实现最小窗口占位计算。**

~~~swift
nonisolated static func inlineEditorFrame(selection: CGRect, visibleFrame: CGRect) -> CGRect {
    let width = max(240, selection.width)
    let height = max(120, selection.height)
    let x = min(selection.minX, max(visibleFrame.minX, visibleFrame.maxX - width))
    let y = min(selection.minY, max(visibleFrame.minY, visibleFrame.maxY - height))
    return selection.union(CGRect(x: x, y: y, width: width, height: height))
}
~~~

通常返回原矩形；小图扩展到屏幕内的可操作区。跨屏用 selection 与目标屏幕的 union 作为可容纳范围，图像必须完整保留；工具锚定目标屏幕可见部分，不能把按钮放到虚拟桌面屏幕间空洞中。测试添加左/下负坐标屏、屏幕右下角及横跨两屏边界。

- [x] **3. 扩展 ImageEditor 布局。** canvasFrame 非 nil 时画布按传入尺寸和中心摆放；默认 nil 保持既有行为：

~~~swift
let rect = canvasFrame ?? CGRect(origin: .zero, size: geometry.size)
ImageEditorCanvas(model: model, revision: model.revision,
                  annotating: annotating && !exporting, onClose: closeEditor)
    .frame(width: rect.width, height: rect.height)
    .position(x: rect.midX, y: rect.midY)
    .accessibilityLabel("截图标注画布")
~~~

工具覆盖层继续独立呈现。window frame 至少容纳 240×120 工具区，选区图片不放大。现有 .frame(minWidth:minHeight:) 仅约束窗口，不强迫 canvas 改变尺寸。模型坐标仍由画布自己的 bounds 映射；window.performDrag 保留。

- [x] **4. 修改 edit 复用窗口。** selectionFrame 非 nil 使用 inlineEditorFrame，否则原 editorFrame。existingWindow 非 nil 就使用该对象，否则才创建新 PinnedImagePanel；设置 frame 不居中。将选区转换为 SwiftUI 局部矩形：

~~~swift
let local = selectionFrame.map {
    CGRect(x: $0.minX - frame.minX, y: frame.maxY - $0.maxY,
           width: $0.width, height: $0.height)
}
~~~

把 local 传给 ImageEditor；保留 weak window 关闭闭包、delegate、editors 持有和 windowWillClose 清理。复用面板 level 改成 floating，保证保存 sheet 不被遮罩级别压住。

- [x] **5. 修改 capture 链路。** 区域选择完成后不马上把 regionSelector 置 nil；保留到 captureEnded。普通 .edit 时将 selectedFrame 与 takeEditorPanel() 传给 edit，绕开 deliver(.edit) 的新窗口路径。copy/download 继续 deliver；成功/取消时 cleanupCapture 调用 regionSelector.cancel 并清空。输出失败时同样转交面板给 edit 保留图片，不能再走居中新窗：

~~~swift
if action == .edit, let selector = regionSelector,
   let frame = selector.selectedFrame, let panel = selector.takeEditorPanel() {
    edit(result, in: panel, selectionFrame: frame)
    message = "可在原选区标注、复制、保存或贴图。"
} else {
    _ = try await deliver(result, action: action)
}
~~~

catch 分支先尝试同样的 selector 转交，再按非区域模式回退 edit(result)。cleanupCapture 增加 selector.cancel 后置 nil；已转交面板不会被该调用关闭。抓取等待超时、进程失败、取消、解码失败都进入同一清理。保留 100ms 隐藏遮罩等待，不能在截图时让遮罩仍显示。

- [x] **6. 运行相关回归。**

~~~bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests -only-testing:FastBudoTests/ImageEditorTests
~~~

覆盖直接复制不创建编辑器、下载取消无输出、无覆盖保存失败保留图片、停止后不写剪贴板；不能因为新增转交而清空已经由编辑器持有的图像。

## Task 3：实机验收与文档

**Files:** docs/guides/screenshot-pin.md、ARCHITECTURE.md、CHANGELOG.md、docs/README.md；更新本计划执行记录。

- [ ] **1. 独立探针与系统检查。** 使用合成图片验证同一个 windowNumber 从选区到编辑、初始位置一致、极小图不拉伸、箭头方向和原始输出像素、直接拖图移动、工具选中、Escape 关闭、保存 sheet。只用专用图片和路径。真实区域截图需验证不含遮罩、选区关闭期间不会居中跳窗、跨屏坐标正确；未有环境则记录未测，不能拿合成图替代。

- [x] **2. 最终回归，窗口测试不并发。**

~~~bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
python3 -m unittest discover -s Tests/ClipboardLifecycle -v
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
~~~

- [x] **3. 同步指南、架构和未发布日志。** 指南说明区域原位编辑、快速动作不弹编辑器、窗口/全屏模式尚未变更、捕获间隔仍短暂隐藏；架构记录 selector→controller 的面板所有权转交。检查和修复所有修改文档的相对链接。

~~~bash
python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .
python3 scripts/check-private-paths.py
git diff --check
~~~

## 执行交接

两项计划可独立实施。推荐继续当前会话顺序执行，先完成源码与测试，再按用户授权安排公开发布或本机安装。需要并行审查时可选择子智能体方式。


## 执行记录（2026-10-28）

代码与本地安装已完成，计划保持 active：真实截图遮罩、多屏混合缩放和极小图 UI 验收仍未完成。

代码与本地构建完成；全量 120 项测试及最终相关回归 50 项通过。完成范围、探针限制、双架构包及外发状态以[验证记录](../../validation/2026-10-28-public-update-source.md)为准。未完成复选框保留，不能将合成图探针视为真实抓图验收；当时尚未安装；后续安装结果见下文，未提交、推送或公开发布。


2026-10-28 后续：用户授权本地重新安装，已完成 0.0.6 固定签名安装和权限/快捷键状态检查，见上述验证记录。


## 选区明暗反馈修正

2026-10-28 用户澄清：编辑时应继续保留选区明亮、外围灰显的整屏界面。此前缩小面板的步骤已被替代：复用面板时保留桌面尺寸、关闭阴影，以独立画布矩形及偶奇遮罩绘制；窗口/全屏截图原流程不变。拖动只移动选区和工具，面板保持固定。新增桌面尺寸、阴影、遮罩透明孔和拖动不绘制回归，实际探针验证结果见[验证记录](../../validation/2026-10-28-public-update-source.md)。
