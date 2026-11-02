---
title: 截图标注工具修复实施计划
status: active
last_updated: 2026-11-02
related_spec: ../specs/2026-11-02-screenshot-annotation-editing-design.md
---

# 截图标注工具修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让截图编辑器的工具条始终位于图片右下角，选中工具即可绘制，文字在图片上就地输入，并让工具切换不再重绘整幅画布。

**Architecture:** 把“图片显示矩形”收拢为纯几何 `EditorLayout`，SwiftUI 工具层与 AppKit 画布共用同一结果；标注开关与工具选择合并进 `ImageEditorModel`；画布只按 `revision` 重绘，并用按 revision 缓存的合成位图承载已完成标注，绘制中的标注单独叠加；文字改为画布子视图 `NSTextField`，提交时生成普通标注。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Testing、CoreGraphics；无新增依赖，不修改 `project.yml`。

**Spec:** [截图标注工具修复设计](../specs/2026-11-02-screenshot-annotation-editing-design.md)

## Global Constraints

- 实施基线为 `~/.codex/worktrees/screenshot-pin/fastbudo`（分支 `codex/integrate-screenshot-main`，HEAD `3da36ac`）。该工作区已有未提交的贴图拖动改动和未跟踪的 `2026-11-02-pinned-image-toolbar*` 文档，不得覆盖、回退或顺手提交。
- 原生 SwiftUI/AppKit 实现，兼容基线保持 Apple Silicon / macOS 27；不引入 Web 壳、后端、插件框架或第三方依赖。
- 保持一次 Escape 关闭当前截图（工具面板、文字输入中同样生效）、保存面板先取消、导出不包含工具层、不覆盖已有输出。
- 标注坐标继续使用原图像素；界面缩放只影响显示，不改变导出尺寸。
- AppKit 窗口、画布、文字输入框和粘贴板操作保持在主线程；画布缓存只随 `revision` 变化。
- 不新增截图模式，不改变捕获、临时目录、20 MiB/四千万像素上限、最多两个编辑器等既有约束。
- 每个任务按“先写失败测试 → 确认失败 → 最小实现 → 通过 → 提交”执行。提交前读 `~/.agents/skills/enforce-conventions/references/commit-attribution.md`，按实际驱动 Agent 追加 `Co-Authored-By`；本计划示例按 DeepSeek Harness 署名。
- 提交前运行 `python3 scripts/check-private-paths.py --staged`；未取得当次授权不得 `git push`。
- 文档任务改完后运行 `python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .`，退出码非零阻断交付。
- 仅用专用临时图片和临时目录做测试，不用用户文件做破坏性样本。

## 现状与决策

- 独立浮窗的 `editorFrame` 分别钳制宽高，极小/极宽图片产生留白；右下角工具按窗口定位，落进留白。区域截图原位编辑把 240×120 工具区并入选区，小选区的工具必然在截图外。
- 工具选择在 popover 内只写 `model.tool`，不关闭面板、不进入标注；`annotating` 由另一个按钮单独控制。用户选完工具后的第一次按下常被 popover 吞掉，或仍处于拖图状态。
- 文字必须先写进 `model.text` 再点图片贴入，画布没有光标。
- `updateNSView` 无条件 `needsDisplay = true`，任何 SwiftUI 状态变化都重放全部标注；马赛克每条都要重新裁剪缩放。
- 决策：工具条锚定图片显示矩形右下角，不移动/放大图片；小到放不下紧凑工具条的选区回退独立窗口，换取“工具一定在截图内”；工具选择即进入标注；文字就地输入；画布按 revision 重绘并缓存已完成标注。
- 极端比例图片（如 300×5000）无法同时满足最小编辑区与屏幕约束时保留旧的分别钳制兜底，允许留白；这一点在指南中写明，不宣称所有比例都无留白。

## 文件地图

| 文件 | 职责 | 任务 |
|---|---|---|
| `App/Screenshot/ImageEditor.swift` | 几何口径、模型状态、工具层定位、画布缓存、文字输入 | 1–5 |
| `App/Screenshot/ScreenshotController.swift` | 浮窗等比布局、原位/独立编辑选择、移除工具区参数 | 1、3 |
| `AppTests/ImageEditorTests.swift` | 几何、工具激活、画布事件、缓存、文字测试 | 1–5 |
| `AppTests/ScreenshotTests.swift` | 浮窗布局、原位契约调整 | 1、3 |
| `docs/guides/screenshot-pin.md` | 用户可见行为 | 6 |
| `ARCHITECTURE.md` | 截图编辑器几何与渲染说明 | 6 |
| `CHANGELOG.md` | 未发布变化 | 6 |
| `docs/README.md` | 文档索引 | 6 |

---

### Task 1: 统一图片显示矩形与浮窗等比布局

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift:34`（`ImageAnnotation` 之后新增 `EditorLayout`）
- Modify: `App/Screenshot/ScreenshotController.swift:328-336`（`editorFrame`）
- Test: `AppTests/ImageEditorTests.swift`（`fixture()` 之前新增用例）
- Test: `AppTests/ScreenshotTests.swift`（`editorWindowFitsVisibleScreen` 之后新增用例）

**Interfaces:**
- Produces:
  - `enum EditorLayout`
  - `static let inset: CGFloat = 8`
  - `static let regularSize: CGSize = CGSize(width: 296, height: 72)`
  - `static let compactSize: CGSize = CGSize(width: 152, height: 92)`
  - `static func imageRect(in bounds: CGRect, imageSize: CGSize) -> CGRect`
  - `static func usesCompactControls(in imageRect: CGRect) -> Bool`
  - `static func fitsToolbar(in size: CGSize) -> Bool`
- 保持 `ScreenshotController.editorFrame(imageSize:visibleFrame:scale:) -> CGRect` 签名不变，行为改为优先等比放大。

- [ ] **Step 1: 构建固定版本引擎**

```bash
cd ~/.codex/worktrees/screenshot-pin/fastbudo
bash scripts/build-engine.sh
```

- [ ] **Step 2: 写失败的几何测试**

在 `AppTests/ImageEditorTests.swift` 的 `fixture()` 之前加入：

```swift
@Test func layoutFitsImageInsideBounds() {
    let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
    #expect(EditorLayout.imageRect(in: bounds, imageSize: CGSize(width: 400, height: 200))
        == CGRect(x: 10, y: 70, width: 400, height: 200))
    #expect(EditorLayout.imageRect(in: bounds, imageSize: CGSize(width: 100, height: 100))
        == CGRect(x: 60, y: 20, width: 300, height: 300))
    #expect(EditorLayout.imageRect(in: .zero, imageSize: CGSize(width: 10, height: 10)) == .zero)
}

@Test func compactControlsFollowImageSize() {
    #expect(!EditorLayout.usesCompactControls(in: CGRect(x: 0, y: 0, width: 400, height: 300)))
    #expect(EditorLayout.usesCompactControls(in: CGRect(x: 0, y: 0, width: 240, height: 120)))
    #expect(EditorLayout.fitsToolbar(in: CGSize(width: 200, height: 120)))
    #expect(!EditorLayout.fitsToolbar(in: CGSize(width: 8, height: 6)))
}
```

- [ ] **Step 3: 运行并确认失败**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests
```

预期：编译失败，`cannot find 'EditorLayout' in scope`。

- [ ] **Step 4: 实现 `EditorLayout`**

在 `App/Screenshot/ImageEditor.swift` 的 `ImageAnnotation` 结束后、`ImageEditorModel` 之前插入：

```swift
/// 编辑器几何口径：SwiftUI 工具层和 AppKit 画布共用，避免两套坐标。
enum EditorLayout {
    static let inset: CGFloat = 8
    static let regularSize = CGSize(width: 296, height: 72)
    static let compactSize = CGSize(width: 152, height: 92)

    /// 在给定矩形内等比完整显示图片；不做 1:1 限制，极小图会放大到可用区域。
    static func imageRect(in bounds: CGRect, imageSize: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func usesCompactControls(in imageRect: CGRect) -> Bool {
        imageRect.width < regularSize.width || imageRect.height < regularSize.height
    }

    /// 选区能否原位容纳两排工具；放不下就回退独立窗口。
    static func fitsToolbar(in size: CGSize) -> Bool {
        size.width >= compactSize.width && size.height >= compactSize.height
    }
}
```

- [ ] **Step 5: 运行几何测试并通过**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests/layoutFitsImageInsideBounds \
  -only-testing:FastBudoTests/ImageEditorTests/compactControlsFollowImageSize
```

- [ ] **Step 6: 写失败的浮窗布局测试**

在 `AppTests/ScreenshotTests.swift` 的 `editorWindowFitsVisibleScreen` 之后加入：

```swift
@Test func editorWindowEnlargesSmallCaptureWithoutDistortion() {
    let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
    let wide = ScreenshotController.editorFrame(
        imageSize: CGSize(width: 400, height: 100), visibleFrame: screen, scale: 2)
    #expect(wide.size == CGSize(width: 480, height: 120))
    #expect(wide.midX == screen.midX)
    #expect(wide.midY == screen.midY)
}
```

- [ ] **Step 7: 运行并确认失败**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ScreenshotTests/editorWindowEnlargesSmallCaptureWithoutDistortion
```

预期：`Expectation failed: wide.size == CGSize(width: 480.0, height: 120.0)`，实际为 `240×120`。

- [ ] **Step 8: 改为等比放大**

把 `ScreenshotController.editorFrame` 替换为：

```swift
nonisolated static func editorFrame(imageSize: CGSize, visibleFrame: CGRect, scale: CGFloat) -> CGRect {
    let available = visibleFrame.insetBy(dx: 16, dy: 16)
    let width = max(1, imageSize.width), height = max(1, imageSize.height)
    let limit = min(available.width / width, available.height / height)
    let base = min(1 / max(1, scale), limit)
    let baseSize = CGSize(width: width * base, height: height * base)
    // 已满足最小编辑区就保持 1:1 或屏幕上限；不足时才整体等比放大，避免宽高分别钳制。
    if baseSize.width < 240 || baseSize.height < 120 {
        let minimum = max(240 / width, 120 / height)
        if width * minimum <= available.width, height * minimum <= available.height {
            let factor = min(max(base, minimum), limit)
            let size = CGSize(width: width * factor, height: height * factor)
            return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        // 极端比例无法同时满足最小编辑区和屏幕约束，保留旧的分别钳制兜底。
        let size = CGSize(width: min(available.width, max(240, baseSize.width)),
                          height: min(available.height, max(120, baseSize.height)))
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    return CGRect(x: available.midX - baseSize.width / 2, y: available.midY - baseSize.height / 2,
                  width: baseSize.width, height: baseSize.height)
}
```

- [ ] **Step 9: 运行相关测试并通过**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests \
  -only-testing:FastBudoTests/ScreenshotTests
```

`editorWindowFitsVisibleScreen` 的 800×600@2 仍应为 400×300；80×40 仍应不小于 240×120。

- [ ] **Step 10: 提交**

```bash
git add App/Screenshot/ImageEditor.swift App/Screenshot/ScreenshotController.swift \
  AppTests/ImageEditorTests.swift AppTests/ScreenshotTests.swift
git commit -m "统一截图编辑器图片显示矩形与浮窗等比布局" \
  -m "Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 2: 选中工具即进入标注

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift:36-67`（`ImageEditorModel` 属性区）
- Modify: `App/Screenshot/ImageEditor.swift:204`（body 中的 `annotating` 参数）
- Modify: `App/Screenshot/ImageEditor.swift:265-288`（`annotationControls`）
- Modify: `App/Screenshot/ImageEditor.swift:310-345`（`toolOptions` 的工具按钮 action）
- Test: `AppTests/ImageEditorTests.swift`（新增工具激活与画布事件测试）

**Interfaces:**
- Produces:
  - `var isAnnotating: Bool`（`ImageEditorModel`）
  - `func select(_ tool: AnnotationTool)`
- Consumes: `AnnotationTool`、`AnnotationCanvas.annotating`、`model.append(_:)`。

- [ ] **Step 1: 写失败的模型与画布测试**

在 `AppTests/ImageEditorTests.swift` 的 `fixture()` 之前加入：

```swift
@Test func selectingToolEntersAnnotation() throws {
    let model = ImageEditorModel(image: try fixture())
    #expect(!model.isAnnotating)
    model.select(.arrow)
    #expect(model.tool == .arrow)
    #expect(model.isAnnotating)
}

@Test(arguments: [AnnotationTool.rectangle, .ellipse, .arrow, .pen, .mosaic])
func dragCreatesAnnotationForTool(_ tool: AnnotationTool) throws {
    let model = ImageEditorModel(image: try fixture())
    model.select(tool)
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    canvas.annotating = true
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), window: window))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 140, y: 130), window: window))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 140, y: 130), window: window))
    #expect(model.annotations.count == 1)
    #expect(model.annotations.first?.tool == tool)
    #expect(((model.annotations.first?.rect.width) ?? 0) > 0)
}

@Test func penAcceptsDragAtImageBottomRight() throws {
    let model = ImageEditorModel(image: try fixture())
    model.select(.pen)
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    canvas.annotating = true
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 380, y: 280), window: window))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 200), window: window))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 300, y: 200), window: window))
    #expect(model.annotations.count == 1)
    #expect(((model.annotations.first?.points.count) ?? 0) >= 2)
}
```

并在文件内加合成事件辅助（放在测试方法之前）：

```swift
private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                       windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                       clickCount: 1, pressure: 1)!
}
```

- [ ] **Step 2: 运行并确认失败**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests
```

预期：`value of type 'ImageEditorModel' has no member 'isAnnotating'`。

- [ ] **Step 3: 给模型加标注开关**

在 `ImageEditorModel` 的 `var text = ""` 之后加入：

```swift
/// 标注开关与工具选择合并，避免“选工具”和“进入标注”互相等待。
var isAnnotating = false
```

在 `append` 之前加入：

```swift
func select(_ tool: AnnotationTool) {
    self.tool = tool
    isAnnotating = true
}
```

- [ ] **Step 4: 运行模型测试并通过**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests/selectingToolEntersAnnotation \
  -only-testing:FastBudoTests/ImageEditorTests/dragCreatesAnnotationForTool \
  -only-testing:FastBudoTests/ImageEditorTests/penAcceptsDragAtImageBottomRight
```

- [ ] **Step 5: 把画笔按钮改为只控制进入/退出**

删除 `@State private var annotating = false`，把 body 中的 `annotating: annotating && !exporting` 改为：

```swift
annotating: model.isAnnotating && !exporting,
```

把 `annotationControls` 开头的画笔按钮替换为下面两个按钮（撤销/重做保留）：

```swift
Button {
    model.isAnnotating.toggle()
    if !model.isAnnotating { options = false }
} label: {
    Image(systemName: "pencil.tip.crop.circle").frame(width: 28, height: 28)
        .background(model.isAnnotating ? PreferencesPalette.selection : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(model.isAnnotating ? PreferencesPalette.primary : .primary)
}
.help(model.isAnnotating ? "标注 · " + model.tool.rawValue + "；再次点击恢复拖动图片" : "标注工具")
.accessibilityLabel("标注工具")
.accessibilityValue(model.isAnnotating ? "已选中：" + model.tool.rawValue : "未选中")
.disabled(exporting)
Button { options.toggle() } label: {
    Image(systemName: model.tool.symbol).frame(width: 28, height: 28)
        .foregroundStyle(model.isAnnotating ? PreferencesPalette.primary : .primary)
}
.help("标注工具：" + model.tool.rawValue)
.accessibilityLabel("标注工具选项")
.accessibilityValue(model.tool.rawValue)
.disabled(exporting)
.popover(isPresented: $options, arrowEdge: .bottom) { toolOptions }
```

- [ ] **Step 6: 选工具后立即进入标注并关闭面板**

把 `toolOptions` 中工具按钮的 action：

```swift
Button { model.tool = tool } label: {
```

改为：

```swift
Button {
    model.select(tool)
    // 文字在 Task 5 之前仍走面板输入，先保留面板；Task 5 改为统一收起。
    if tool != .text { options = false }
} label: {
```

- [ ] **Step 7: 运行编辑器测试并通过**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests
```

复制、保存、Escape 的既有用例应继续通过；“标注工具”与“标注工具选项”是两个不同的可访问性标签。

- [ ] **Step 8: 提交**

```bash
git add App/Screenshot/ImageEditor.swift AppTests/ImageEditorTests.swift
git commit -m "选中截图标注工具后直接进入绘制" \
  -m "Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 3: 工具条锚定图片右下角并降级小选区

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift:184-192`（`init` 去掉 `controlsFrame`）
- Modify: `App/Screenshot/ImageEditor.swift:194-240`（`body` 与新增 `controlsOverlay`）
- Modify: `App/Screenshot/ScreenshotController.swift:311-320`（`editCapturedImage` 门槛）
- Modify: `App/Screenshot/ScreenshotController.swift:338-345`（删除 `inlineEditorFrame`）
- Modify: `App/Screenshot/ScreenshotController.swift:346-380`（不再计算 `toolsFrame`/`controlsFrame`）
- Test: `AppTests/ScreenshotTests.swift`（删除 `inlineEditorKeepsSelectionPosition`）

**Interfaces:**
- Consumes: `EditorLayout.imageRect(in:imageSize:)`、`EditorLayout.usesCompactControls(in:)`、`EditorLayout.fitsToolbar(in:)`、`EditorLayout.inset`。
- Produces: `ImageEditor.init(image:window:pasteboard:canvasFrame:onPin:onClose:)`（移除 `controlsFrame`）。

- [ ] **Step 1: 先删掉固化了错误行为的测试**

从 `AppTests/ScreenshotTests.swift` 删除整个 `inlineEditorKeepsSelectionPosition` 测试。它断言小选区仍原位并扩展 240×120 工具区，与本任务的新契约冲突。保留 `inlineEditorReusesPanelAndPreservesPixels` 与 `editorWindowFitsVisibleScreen`。

- [ ] **Step 2: 改动 `ImageEditor` 初始化**

把属性与 init 改为：

```swift
private let canvasFrame: CGRect?
let onPin: (NSImage) -> Void
let onClose: () -> Void

init(image: NSImage, window: NSWindow, pasteboard: NSPasteboard = .general,
     canvasFrame: CGRect? = nil,
     onPin: @escaping (NSImage) -> Void, onClose: @escaping () -> Void) {
    _model = State(initialValue: ImageEditorModel(image: image))
    self.window = window; self.pasteboard = pasteboard
    self.canvasFrame = canvasFrame
    self.onPin = onPin; self.onClose = onClose
}
```

- [ ] **Step 3: 替换 `body` 的定位**

用下面代码替换 `body` 中的 `GeometryReader` 内容（保留 `.frame(minWidth: 240, minHeight: 120)` 及其后的修饰符）：

```swift
GeometryReader { geometry in
    let canvasRect = canvasFrame?.offsetBy(dx: imageOffset.width, dy: imageOffset.height)
        ?? CGRect(origin: .zero, size: geometry.size)
    let imageRect = EditorLayout.imageRect(in: canvasRect, imageSize: model.size)
    ZStack(alignment: .topLeading) {
        if canvasFrame != nil {
            ScreenshotSelectionShade(selection: canvasRect)
                .fill(.black.opacity(0.18), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
        }
        ImageEditorCanvas(model: model, revision: model.revision,
            annotating: model.isAnnotating && !exporting,
            onClose: closeEditor,
            onMove: canvasFrame == nil ? nil : { delta in
                guard !exporting else { return }
                imageOffset.width += min(max(delta.width, -canvasRect.minX), geometry.size.width - canvasRect.maxX)
                imageOffset.height += min(max(delta.height, -canvasRect.minY), geometry.size.height - canvasRect.maxY)
            })
            .frame(width: canvasRect.width, height: canvasRect.height)
            .overlay {
                if canvasFrame != nil { Rectangle().strokeBorder(.red, lineWidth: 1).allowsHitTesting(false) }
            }
            .position(x: canvasRect.midX, y: canvasRect.midY)
            .accessibilityLabel("截图标注画布")
        controlsOverlay(imageRect: imageRect)
    }
}
```

- [ ] **Step 4: 新增工具层定位方法**

在 `closeEditor` 之后加入：

```swift
/// 工具层以图片显示矩形为锚点：宽度至少容纳常规工具条，右下角贴图片内边缘。
private func controlsOverlay(imageRect: CGRect) -> some View {
    let width = max(imageRect.width, EditorLayout.regularSize.width)
    let height = max(imageRect.height, 0)
    return VStack(alignment: .trailing, spacing: 6) {
        if exporting {
            ProgressView("正在导出…").padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else if let notice {
            Text(notice).font(.caption).padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        controls(compact: EditorLayout.usesCompactControls(in: imageRect))
    }
    .frame(width: width, height: height, alignment: .bottomTrailing)
    .padding(EditorLayout.inset)
    .offset(x: imageRect.maxX - width - EditorLayout.inset * 2,
            y: imageRect.maxY - height - EditorLayout.inset * 2)
}
```

- [ ] **Step 5: 小选区回退独立窗口**

把 `editCapturedImage` 改为：

```swift
private func editCapturedImage(_ image: NSImage) {
    if let selector = regionSelector, let frame = selector.selectedFrame,
       EditorLayout.fitsToolbar(in: frame.size),
       let panel = selector.takeEditorPanel() {
        edit(image, in: panel, selectionFrame: frame)
        message = "可在原选区标注、复制、保存或贴图。"
    } else {
        edit(image)
        message = "截图已打开，可标注、复制、保存或贴图。"
    }
}
```

选区小于紧凑工具条时不再取面板，`defer cleanupCapture()` 会关闭选区遮罩，独立窗口由 `edit(image)` 等比放大显示，工具落在图片内。

- [ ] **Step 6: 删除 `inlineEditorFrame` 与控制器里的工具区计算**

删除 `ScreenshotController.inlineEditorFrame`。在 `edit(_:in:selectionFrame:)` 中删除：

```swift
let toolsFrame = selectionFrame.map { Self.inlineEditorFrame(selection: $0, visibleFrame: screen.visibleFrame) }
```

以及：

```swift
let visible = (toolsFrame ?? frame).intersection(screen.visibleFrame)
let controlsFrame = selectionFrame.map { _ in
    CGRect(x: visible.minX - frame.minX, y: frame.maxY - visible.maxY, width: visible.width, height: visible.height)
}
```

把 `ImageEditor(...)` 调用改为：

```swift
window.contentView = NSHostingView(rootView: ImageEditor(image: image, window: window,
    canvasFrame: canvasFrame,
    onPin: { [weak self] in self?.pin($0) }, onClose: { [weak window] in window?.close() }))
```

- [ ] **Step 7: 编译并运行截图测试**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ScreenshotTests \
  -only-testing:FastBudoTests/ImageEditorTests
```

预期：`inlineEditorReusesPanelAndPreservesPixels` 仍通过（panel 仍是整屏、无阴影、关闭后 contentView 清空）；工具条位置由 Task 1 的几何用例和 Task 6 的实机清单覆盖。

- [ ] **Step 8: 提交**

```bash
git add App/Screenshot/ImageEditor.swift App/Screenshot/ScreenshotController.swift AppTests/ScreenshotTests.swift
git commit -m "截图工具条锚定图片右下角并对小选区回退独立窗口" \
  -m "Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 4: 按 revision 重绘并缓存已完成标注

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift:110-158`（`draw(_:)` 改名）
- Modify: `App/Screenshot/ImageEditor.swift:405-415`（`updateNSView`）
- Modify: `App/Screenshot/ImageEditor.swift:419-470`（画布缓存与 `sync`）
- Test: `AppTests/ImageEditorTests.swift`（新增重绘门槛与缓存测试）

**Interfaces:**
- Produces:
  - `ImageEditorModel.draw(annotation:)`
  - `AnnotationCanvas.sync(model:revision:annotating:onClose:onMove:)`
  - `AnnotationCanvas.backdropBuilds`（只读计数，测试用）
- Consumes: `ImageEditorModel.revision`、`rendered()`。

- [ ] **Step 1: 写失败的重绘测试**

在 `AppTests/ImageEditorTests.swift` 的 `fixture()` 之前加入：

```swift
@Test func toolSwitchDoesNotRedrawCanvas() throws {
    let model = ImageEditorModel(image: try fixture())
    let canvas = AnnotationCanvas(model: model, onClose: {})
    canvas.sync(model: model, revision: model.revision, annotating: false, onClose: {}, onMove: nil)
    canvas.needsDisplay = false
    model.select(.arrow)
    canvas.sync(model: model, revision: model.revision, annotating: true, onClose: {}, onMove: nil)
    #expect(!canvas.needsDisplay)
}

@Test func backdropRebuildsOnlyOnRevisionChange() throws {
    let model = ImageEditorModel(image: try fixture())
    let canvas = AnnotationCanvas(model: model, onClose: {})
    canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    func render() throws {
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    try render()
    try render()
    #expect(canvas.backdropBuilds == 1)
    model.append(ImageAnnotation(tool: .rectangle,
        points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)]))
    canvas.sync(model: model, revision: model.revision, annotating: false, onClose: {}, onMove: nil)
    try render()
    #expect(canvas.backdropBuilds == 2)
}
```

- [ ] **Step 2: 运行并确认失败**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests/toolSwitchDoesNotRedrawCanvas \
  -only-testing:FastBudoTests/ImageEditorTests/backdropRebuildsOnlyOnRevisionChange
```

预期：`value of type 'AnnotationCanvas' has no member 'sync'`。

- [ ] **Step 3: 让模型支持单独绘制一条标注**

把 `private func draw(_ mark: ImageAnnotation)` 改为：

```swift
func draw(annotation mark: ImageAnnotation) {
```

并把 `draw(pending:)` 中两处 `draw(annotation)` 改为：

```swift
draw(annotation: annotation)
```

以及：

```swift
if let pending { draw(annotation: pending) }
```

- [ ] **Step 4: 给画布加 revision 门槛与 backdrop 缓存**

在 `AnnotationCanvas` 的 `pending` 之后加入：

```swift
private var displayedRevision = -1
private var backdropImage: NSImage?
private var backdropRevision = -1
private(set) var backdropBuilds = 0
```

把 `imageRect` 改为：

```swift
private var imageRect: CGRect { EditorLayout.imageRect(in: bounds, imageSize: model.size) }
```

在 `draw` 之前加入：

```swift
/// 已完成标注只随 revision 重建一次；绘制中的标注另画，避免每次状态变化重放全部标注。
private func backdrop() -> NSImage? {
    if backdropRevision != model.revision {
        backdropImage = try? model.rendered()
        backdropRevision = model.revision
        backdropBuilds += 1
    }
    return backdropImage
}

func sync(model: ImageEditorModel, revision: Int, annotating: Bool,
          onClose: @escaping () -> Void, onMove: ((CGSize) -> Void)?) {
    if self.model !== model {
        self.model = model
        backdropImage = nil
        backdropRevision = -1
        displayedRevision = -1
    }
    self.onClose = onClose
    self.onMove = onMove
    self.annotating = annotating
    guard revision != displayedRevision else { return }
    displayedRevision = revision
    needsDisplay = true
}
```

- [ ] **Step 5: 重写 `draw` 使用缓存**

```swift
override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill(); bounds.fill(using: .copy)
    let rect = imageRect
    guard rect.width > 0, rect.height > 0 else { return }
    if let image = backdrop() {
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        guard let pending, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / model.size.width, y: rect.height / model.size.height)
        model.draw(annotation: pending)
        context.restoreGState()
    } else if let context = NSGraphicsContext.current?.cgContext {
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / model.size.width, y: rect.height / model.size.height)
        model.draw(pending: pending)
        context.restoreGState()
    }
}
```

- [ ] **Step 6: 让 SwiftUI 更新走 `sync`**

把 `ImageEditorCanvas.updateNSView` 替换为：

```swift
func updateNSView(_ view: AnnotationCanvas, context: Context) {
    view.sync(model: model, revision: revision, annotating: annotating, onClose: onClose, onMove: onMove)
}
```

`makeNSView` 保持不变。

- [ ] **Step 7: 运行并确认通过**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests
```

- [ ] **Step 8: 提交**

```bash
git add App/Screenshot/ImageEditor.swift AppTests/ImageEditorTests.swift
git commit -m "截图标注画布按 revision 重绘并缓存已完成标注" \
  -m "Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 5: 文字工具在图片上就地输入

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift:44-50`（删除 `model.text`）
- Modify: `App/Screenshot/ImageEditor.swift:335-337`（删除工具面板 TextField）
- Modify: `App/Screenshot/ImageEditor.swift:347-380`（导出前提交文字）
- Modify: `App/Screenshot/ImageEditor.swift:419-495`（画布文字输入与提交）
- Test: `AppTests/ImageEditorTests.swift`（新增文字用例）

**Interfaces:**
- Produces:
  - `AnnotationCanvas.textField: NSTextField?`（只读）
  - `func beginTextEditing(at point: CGPoint)`
  - `func commitTextEditing()`
- Consumes: `model.width`、`model.color`、`model.size`、`EditorLayout.imageRect(in:imageSize:)`、`model.append(_:)`。

- [ ] **Step 1: 写失败的就地文字测试**

在 `AppTests/ImageEditorTests.swift` 的 `fixture()` 之前加入（`textFixture` 用 800×600 像素、400×300 点的图片，让字号和输入框尺寸接近真实截图）：

```swift
private func textFixture() throws -> NSImage {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let image = NSImage(size: NSSize(width: 400, height: 300))
    image.addRepresentation(rep)
    return image
}

@Test func textToolStartsInlineEditingAndCommitsOnReturn() throws {
    let model = ImageEditorModel(image: try textFixture())
    model.select(.text)
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    canvas.annotating = true
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), window: window))
    let field = try #require(canvas.textField)
    #expect(field.frame.minX >= 0 && field.frame.minY >= 0)
    #expect(field.frame.maxX <= canvas.bounds.width && field.frame.maxY <= canvas.bounds.height)
    field.stringValue = "标注"
    #expect(canvas.control(field, textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(model.annotations.count == 1)
    #expect(model.annotations.first?.text == "标注")
    #expect(canvas.textField == nil)
}

@Test func emptyTextCommitAddsNothing() throws {
    let model = ImageEditorModel(image: try textFixture())
    model.select(.text)
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    canvas.annotating = true
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), window: window))
    let field = try #require(canvas.textField)
    field.stringValue = "   "
    canvas.commitTextEditing()
    #expect(model.annotations.isEmpty)
    #expect(canvas.textField == nil)
}
```

- [ ] **Step 2: 运行并确认失败**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests/textToolStartsInlineEditingAndCommitsOnReturn \
  -only-testing:FastBudoTests/ImageEditorTests/emptyTextCommitAddsNothing
```

预期：`value of type 'AnnotationCanvas' has no member 'textField'`。

- [ ] **Step 3: 删除旧的“先输入后贴入”**

从 `ImageEditorModel` 删除 `var text = ""`。从 `toolOptions` 删除：

```swift
if model.tool == .text {
    TextField("输入文字后在图片上点击", text: $model.text).textFieldStyle(.roundedBorder)
}
```

把 Task 2 保留的面板条件去掉，文字工具也统一收起面板：

```swift
Button { model.select(tool); options = false } label: {
```

- [ ] **Step 4: 给画布加文字输入状态**

把类声明改为：

```swift
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
```

在 `pending` 之后加入：

```swift
private(set) var textField: NSTextField?
private var textPoint: CGPoint?
private var textWidth: CGFloat = 4
private var textColor: NSColor = .systemRed
private var editingTool: AnnotationTool = .text
```

- [ ] **Step 5: 实现开始输入与提交**

在 `point(_:)` 之后加入：

```swift
func beginTextEditing(at point: CGPoint) {
    commitTextEditing()
    let rect = imageRect
    guard rect.width > 0, rect.height > 0 else { return }
    let scale = rect.width / model.size.width
    let fontSize = max(16, CGFloat(model.width) * 5) * scale
    let origin = CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
    let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y,
                                          width: min(320, max(80, rect.maxX - origin.x)),
                                          height: fontSize * 1.5))
    field.font = .systemFont(ofSize: fontSize, weight: .medium)
    field.textColor = NSColor(model.color)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.delegate = self
    addSubview(field)
    textField = field
    textPoint = point
    textWidth = CGFloat(model.width)
    textColor = NSColor(model.color)
    editingTool = model.tool
    window?.makeFirstResponder(field)
}

func commitTextEditing() {
    guard let field = textField else { return }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let point = textPoint
    textField = nil
    textPoint = nil
    field.delegate = nil
    window?.makeFirstResponder(self)
    field.removeFromSuperview()
    if let point, !text.isEmpty {
        model.append(ImageAnnotation(tool: .text, points: [point], color: textColor,
                                     width: textWidth, text: String(text.prefix(2000))))
    }
    needsDisplay = true
}

func controlTextDidEndEditing(_ notification: Notification) {
    guard textField != nil else { return }
    commitTextEditing()
}

func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
    commitTextEditing()
    return true
}
```

- [ ] **Step 6: 文字工具改为点击出光标**

把 `mouseDown` 中从 `let point = point(event)` 到末尾替换为：

```swift
let point = point(event)
if model.tool == .text {
    beginTextEditing(at: point)
    return
}
let mark = ImageAnnotation(tool: model.tool, points: [point],
                           color: NSColor(model.color), width: model.width)
pending = mark
needsDisplay = true
```

并在 `sync` 中、`self.annotating = annotating` 之前加入（提交会改变 revision，先把新 revision 记为已显示，避免多一次整图重建）：

```swift
if textField != nil, !annotating || editingTool != model.tool {
    commitTextEditing()
    displayedRevision = model.revision
    needsDisplay = true
    return
}
```

- [ ] **Step 7: 导出前提交未结束的文字**

在 `perform` 的 `guard !exporting else { return }` 之后加入：

```swift
window?.makeFirstResponder(nil)
```

在 `save` 的 `guard !exporting, let window else { return }` 之后加入：

```swift
window.makeFirstResponder(nil)
```

- [ ] **Step 8: 运行文字与编辑器测试**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:FastBudoTests/ImageEditorTests
```

`textToolStartsInlineEditingAndCommitsOnReturn` 的 `field.frame.maxX <= canvas.bounds.width` 依赖点击点在图片中部；若字段宽度被 320 或剩余宽度限制，仍在画布内。Escape、复制、保存用例应保持通过。

- [ ] **Step 9: 提交**

```bash
git add App/Screenshot/ImageEditor.swift AppTests/ImageEditorTests.swift
git commit -m "文字标注改为在截图上就地输入" \
  -m "Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 6: 更新用户文档、索引与全量验证

**Files:**
- Modify: `docs/guides/screenshot-pin.md:15`（用户可见行为）
- Modify: `ARCHITECTURE.md:73-75`（编辑几何与工具层）
- Modify: `CHANGELOG.md`（未发布区顶部）
- Modify: `docs/README.md`（索引行与 `last_updated`）
- Test: 全量 `FastBudoTests`、Release 构建、治理门禁

**Interfaces:**
- Consumes: Task 1–5 的行为。
- Produces: 与实现一致的用户文档和索引。

- [ ] **Step 1: 改写用户指南**

把 `docs/guides/screenshot-pin.md:15` 中包含“工具位于选区右下角；小选区允许工具显示在选区外，不拉伸图片。”和“点击画笔标注按钮后高亮并进入绘制……再次点击标注按钮退出绘制”的段落改为：

```text
区域选取完成后继续在整屏选区界面编辑：选区保持明亮，外围灰显。工具条固定在图片显示区域的右下角，图片缩小时工具条同步收缩为两排，不脱离图片；选区小到放不下两排工具时，改用独立编辑窗口按比例放大显示，工具仍在图片内。图片宽高比不变，不为摆放工具拉伸图片。

点击画笔按钮进入或退出标注；右侧按钮显示当前工具，点击展开工具面板，选中任一工具后面板自动收起并直接进入绘制，在图片上拖动即可。箭头、画笔与矩形、椭圆、马赛克使用同一套流程。文字工具不再需要先输入：点击图片出现插入光标，就地输入，回车或点击别处提交；空文字不生成标注。撤销、重做、颜色和笔宽仍可用。

未进入标注时，独立窗口拖动图片移动窗口，原位编辑拖动图片只移动选区与工具。小选区回退时选区遮罩先关闭，再出现独立窗口，会有一次窗口切换。极端宽高比（如 300×5000）无法同时满足最小编辑区与屏幕时，图片会留白，工具条仍按图片右下角定位，可能盖出图片。工具面板或文字输入中一次 Escape 仍直接关闭当前截图；保存面板先取消。导出不包含工具条或输入框。
```

同时更新该文件末尾“验证边界”，写明本轮自动测试覆盖几何、六工具事件、缓存与文字提交；真实区域截图、多屏混合缩放、极小/极端比例图片仍需实机复核，Intel 未验证。

- [ ] **Step 2: 更新架构文档**

把 `ARCHITECTURE.md:73` 中“图片点矩形与原始像素、透明工具占位区分别处理，工具位于目标屏可见区。”改为：

```text
图片点矩形与原始像素分开保留，工具条锚定图片显示区域的右下角；图片显示矩形由画布与 SwiftUI 共用同一份等比计算。选区放不下两排工具时改用独立窗口等比放大显示，不再把工具区并入选区。
```

把 `ARCHITECTURE.md:75` 的工具层说明补一句：

```text
画布只按标注 revision 重绘，已完成标注缓存为合成位图；工具切换和文字输入不触发整图重放。文字由画布子视图就地输入，提交后成为普通标注。
```

- [ ] **Step 3: 更新变更日志**

在 `CHANGELOG.md` 的 `## 未发布` 下最前面加入：

```markdown
- 截图标注工具条固定在图片显示区域右下角；小选区改用独立窗口等比放大，工具不再落到截图外。
- 选中标注工具后直接进入绘制，箭头、画笔与矩形等工具行为一致；文字改为在图片上点击后就地输入。
- 标注画布按 revision 重绘并缓存已完成标注，切换工具不再重放整幅图片。
```

- [ ] **Step 4: 登记文档索引**

在 `docs/README.md` 的表格第一行加入：

```markdown
| 修复截图标注工具位置、箭头画笔与就地文字 | [设计](superpowers/specs/2026-11-02-screenshot-annotation-editing-design.md) / [实施计划](superpowers/plans/2026-11-02-screenshot-annotation-editing.md) |
```

把 frontmatter 的 `last_updated` 改为 `2026-11-02`。

- [ ] **Step 5: 运行治理门禁**

```bash
cd ~/.codex/worktrees/screenshot-pin/fastbudo
python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .
git diff --check
```

任一非零退出即停止，修正后重跑。

- [ ] **Step 6: 运行全量测试与 Release 构建**

```bash
bash scripts/build-engine.sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
```

- [ ] **Step 7: 实机清单**

在真实应用里逐项记录（不能用合成事件代替）：

1. 普通区域截图（如 400×300 点）：工具条完整位于图片右下角，两个按钮行都在图片内。
2. 极小区域（如 40×30 点）：进入独立窗口，图片放大且宽高比不变，工具条在图片内。
3. 宽而矮的窗口截图（如 600×120 像素）：工具条仍在图片右下角；极宽/极高图片记录留白与工具是否盖出，不宣称完全在图片内。
4. 箭头、画笔各画一笔；先点工具再回画布，第一次按下即产生标注。
5. 文字工具点击后出现光标，输入并回车；位置、字号、颜色与导出 PNG 一致；点击别处也能提交；空白文字不生成标注。
6. 打开约 4000×3000 截图，连续切换六个工具、颜色和笔宽，拖动绘制时无可感知卡顿。
7. 工具面板打开、文字输入中按一次 Escape，均关闭当前截图；保存面板先取消。
8. 多屏混合缩放若未实测，在记录中写明未覆盖；Intel 未验证。

- [ ] **Step 8: 提交文档**

```bash
git add docs/superpowers/specs/2026-11-02-screenshot-annotation-editing-design.md \
  docs/superpowers/plans/2026-11-02-screenshot-annotation-editing.md \
  docs/guides/screenshot-pin.md ARCHITECTURE.md CHANGELOG.md docs/README.md
python3 scripts/check-private-paths.py --staged
git commit -m "同步截图标注工具修复的用户文档与索引" \
  -m "Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

## 自检

**Spec 覆盖**

- 工具条位置：Task 1 的 `imageRect` + Task 3 的 `controlsOverlay`。
- 小选区不再把工具放在截图外：Task 3 的 `fitsToolbar` 门槛与独立窗口回退。
- 箭头、画笔不可用：Task 2 的 `select` 即进入标注、工具面板关闭、画布事件测试。
- 文字就地输入：Task 5 的 `NSTextField` 生命周期、Enter/失焦/导出提交、空文字丢弃。
- 切换卡帧：Task 4 的 revision 门槛、backdrop 缓存、pending 单独绘制。
- 既有 ESC、导出、保存、撤销行为：Task 6 全量回归与实机清单。

**占位符检查**

- 无 TBD/TODO/“类似 Task N”/“适当错误处理”；每个代码步骤给出可直接粘贴的实现。
- 示例署名按 DeepSeek Harness 写；实施 Agent 不同时按 `commit-attribution.md` 替换 Name/Email，不改变格式。

**类型一致性**

- `EditorLayout` 的常量与三个几何方法在 Task 1 定义，Task 3 只消费；签名不再变化。
- `sync(model:revision:annotating:onClose:onMove:)` 在 Task 4 定义，Task 5 只在其内部追加文字提交，不改变签名。
- `ImageEditor` 初始化在 Task 3 去掉 `controlsFrame`；控制器与测试的调用点同步更新，默认参数保证未显式传参的测试仍编译。
- `draw(annotation:)` 在 Task 4 改名，`draw(pending:)` 与画布缓存两处调用同步更新。

## 执行交接

计划完成，两种执行方式二选一：

1. **子代理驱动（推荐）**：每个 Task 交给一个独立子代理，按 Step 执行并在提交后回报测试输出；主代理只做任务间审查，重点看 Task 3 的视图定位与 Task 5 的文字焦点时序。
2. **内联执行**：在当前会话按 Task 顺序执行，每个 Task 结束运行对应测试并提交；Task 6 的全量测试和实机清单必须在同一轮完成，不得用自动测试代替实机结论。

无论哪种方式，先确认工作区是 `~/.codex/worktrees/screenshot-pin/fastbudo`，并保留其中已有的贴图拖动未提交改动与未跟踪文档。

本设计与计划写在主工作区的 `docs/superpowers/` 下。开始实施前，先把这两个文件复制到 worktree 的同一路径（它们随 Task 6 一起提交），否则 Task 6 的索引会指向不存在的文件：

```bash
cp ~/project/fastbudo/docs/superpowers/specs/2026-11-02-screenshot-annotation-editing-design.md \
  docs/superpowers/specs/
cp ~/project/fastbudo/docs/superpowers/plans/2026-11-02-screenshot-annotation-editing.md \
  docs/superpowers/plans/
```

## 交付后调整

2026-11-02 用户复测后明确：工具条应放在图片外侧，而不是图片内右下角。实现改为 `EditorLayout.toolbarOrigin`：优先图片下方外侧、右对齐；下方放不下翻到上方；上下都放不下才重叠进图片。区域截图不再按选区尺寸回退独立窗口；独立窗口为工具条预留高度。
