---
title: 文字标注工具“边框盒子”实施计划
status: active
last_updated: 2026-11-05
related_spec: ../specs/2026-11-02-screenshot-annotation-editing-design.md
---

# 文字标注工具“边框盒子” Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 1) 让截图编辑器“锚点工具栏”里的文字标注工具支持：文字画在带边框和底色、可设定宽高的盒子里；盒内文字按盒宽自动换行；提交后仍可点选该文字盒子整体拖动改位置，并可拖右下角改盒子尺寸。2) 让截图贴图窗口提升为置顶层，避免被如 utools 的更高层级弹出框遮挡。3) 修复本地重新安装后 macOS TCC 权限（屏幕录制、辅助功能、文件等）反复被重置的问题：本地安装改用具固定证书的 `scripts/sign-local.sh` 签名，使各版本被系统识别为同一 App、权限跨重装保留。

**Architecture:** 文字标注的几何从“裸文本 + 一个锚点”改为“边框盒子”模型：`ImageAnnotation` 对 `.text` 类型用两点（左上、右下）表示盒子矩形；`draw(annotation:)` 对 `.text` 走“圆角底色 + 描边 + 自动换行文本”渲染，缺盒子时回退为旧的单行绘制以兼容存量；`AnnotationCanvas` 的文本输入改为“按下并拖动先划盒子、松开再就地输入”，并新增“命中已有文字盒子 → 拖动整体移动 + 拖角缩放”的选中编辑态。所有坐标继续沿用原图像素，导出不受预览缩放影响。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Testing、CoreGraphics；无新增依赖，不修改 `project.yml`。

**Spec:** 需求来自用户交付（m01489）与需求澄清（m01520，用户选“有边框文本框 + 提交后可再选中移动”）。前置设计说明见 [截图标注工具修复设计](../specs/2026-11-02-screenshot-annotation-editing-design.md)（文字就地输入、工具选择即标注、标注坐标使用原图像素等约定继续沿用）。无独立新 spec 文档，本计划内“现状与决策”即设计。

## Global Constraints

- 实现基线为当前工作目录（仓库根，`main` = `4e09f29`，工作区 clean）。
- 原生 SwiftUI/AppKit 实现，兼容基线保持 Apple Silicon / macOS 27；不引入 Web 壳、后端、插件框架或第三方依赖。
- 标注坐标继续使用原图像素；界面缩放只影响显示，不改变导出尺寸；画布缓存只随 `revision` 变化。
- 文字字号仍由现有“笔宽 / 字号”滑杆（`model.width`，范围 2...20）统一驱动，字号＝`max(16, width*5)`（本次不新增分辨率/字号设置）。
- 保持一次 Escape 关闭当前截图、先保存先取消、导出不包含工具层、不覆盖已有输出、标注上限 200 条等既有约束。
- AppKit 窗口、画布、文字输入框和粘贴板操作保持在主线程；画布缓存只随 `revision` 变化。
- 每个任务按“先写失败测试 → 确认失败 → 最小实现 → 通过 → 提交”执行。提交前读 `~/.agents/skills/enforce-conventions/references/commit-attribution.md`，按实际驱动 Agent 追加 `Co-Authored-By`；本计划示例按 DeepSeek Harness 署名。
- 提交前运行 `python3 scripts/check-private-paths.py --staged`；未取得当次授权不得 `git push`（本计划只提交本地）。
- 文档任务改完后运行 `python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .`，退出码非零阻断交付。
- 仅用专用临时图片和临时目录做测试，不用用户文件做破坏性样本。
- 验证：本机环境无法启动 `xcodebuild test` runner（无伪终端），用 `xcodebuild ... build-for-testing` 验证测试目标可编译，并在计划“验证边界”注明真机 UI 走查未自动化。

## 现状与决策

**现状（App/Screenshot/ImageEditor.swift）：**
- `ImageAnnotation(21-33)`：`tool / points / color / width / text`；`rect` 由 `first/last` 的 min/max 得到。`draw(annotation:.text)(200-203)`：直接 `(text as NSString).draw(at: first, withAttributes:[.font, .foregroundColor])` — **裸单行文本、无边框底色**。
- `AnnotationCanvas.beginTextEditing(at:)(538-566)`：点击即建 `NSTextField`（宽 `max(160, fontSize*8)`），单行输入。
- `commitTextEditing()(568-582)`：提交时存 `points: [origin, CGPoint(x: origin.x + fontSize, y: origin.y)]` — 即一条水平段，仅把“字号”宽度当框宽。
- `mouseDown(675-691)`：`model.tool == .text` 时直接 `beginTextEditing(at: point(event))`；无“先划框、再输入”，无“选中已有盒子移动/缩放”。
- `draw(_:)(646-667)`：backdrop + pending 叠加，无“选中高亮/缩放柄”绘制。

**用户需求（m01489 原文）：**“锚点工具栏里的文字标注工具支持设置边框的大小，同时支持调整位置，边框不足时自动换行”。
**需求澄清（m01520，用户选定）：**“文字绘制在带边框/背景的盒子里，盒子宽高可调（文字自动换行贴合）；提交后仍可点选该文字框整体拖动改位置。”

**决策：**
1. `.text` 标注的 `points` 改为两点（左上、右下）＝盒子矩形。旧的单点/横向段标注无有效盒子 → 渲染回退旧的单行绘制，保证既有测试与存量不崩。
2. 划框式输入：文字工具下“按下并拖动＝定盒子大小，松开＝就地输入”；单独单击（拖距过小）则用默认盒宽（`max(200, fontSize*8)`）就地输入。
3. 选中编辑态：文字工具下点击命中已有文字盒子 → 选中框亮显 + 右下角缩放柄；拖动盒子或缩放柄实时改模型并通过 `revision` 重绘；松开后保持。
4. 渲染：盒子＝白底高不透明圆角 + 主题色描边 + `NSString.draw(with:options:usesLineFragmentOrigin)` 自动换行文本，文字按 `insetBy(6,5)` 内缩。
5. 文末追加。字号仍走 `max(16, width*5)`。导出的就是盒子渲染结果，无额外图层。

## 文件地图

| 文件 | 职责 | 任务 |
|---|---|---|
| `App/Screenshot/ImageEditor.swift` | 文字盒子模型方法、`draw` 盒子渲染、画布划框输入与命中移动/缩放 | 1–3 |
| `AppTests/ImageEditorTests.swift` | 盒子渲染换行、划框提交、命中移动、缩放、既有文字测试适配 | 1–3 |
| `App/Screenshot/PinnedImage.swift` | 贴图窗口层级置顶 | 5 |
| `scripts/sign-local.sh` | 本机固定身份签名（已有，Task 6 复用/复核） | 6 |
| `scripts/install-local.sh` | 新增：构建 → sign-local → 替换 /Applications → 重启 | 6 |
| `CHANGELOG.md` | 未发布变化 | 4 |
| `docs/guides/screenshot-pin.md` | 用户可见行为 | 4 |
| `ARCHITECTURE.md` | 编辑器标注几何与渲染说明 | 4 |
| `docs/README.md` | 文档索引 | 4 |

---

### Task 1: 文字盒子渲染与模型位移/缩放方法

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift:182-221`（`draw(annotation:)` 的 `.text` 分支）
- Modify: `App/Screenshot/ImageEditor.swift:114-127`（`append`/`undo`/`redo` 之后新增 `translate(_:by:)` 与 `setTextSize(at:box:)`）
- Test: `AppTests/ImageEditorTests.swift`

**Interfaces:**
- Consumes: `ImageAnnotation.tool/.points/.color/.width/.text`、`ImageAnnotation.rect`、`ImageEditorModel.annotations`（private(set) 读）、`ImageEditorModel.revision`。
- Produces:
  - `ImageEditorModel.translate(_ index: Int, by offset: CGSize)` — 整体平移第 `index` 条标注的所有点，`revision += 1`。
  - `ImageEditorModel.setTextSize(at index: Int, box: CGRect)` — 仅对 `.text` 标注把 `points` 重写为 `[box.minX/minY, box.maxX/maxY]`，`revision += 1`。
  - `draw(annotation:)` 对 `.text`：有效盒子（`rect.width/height >= 2`）走“圆角白底 + 描边 + 自动换行文本”，否则回退旧单行。

- [ ] **Step 1: 写失败测试**

在 `AppTests/ImageEditorTests.swift` 新增测试（放在 `everyAnnotationToolChangesExportedPixels` 之后）：

```swift
@Test func translateAndResizeTextBoxUpdatePixels() async throws {
    let model = ImageEditorModel(image: try fixture())
    model.select(.text)
    model.append(ImageAnnotation(tool: .text,
                                 points: [CGPoint(x: 10, y: 8), CGPoint(x: 30, y: 20)],
                                 color: .systemGreen, width: 4, text: "A"))
    let before = try await model.png()
    model.translate(0, by: CGSize(width: 5, height: 5))
    let moved = try await model.png()
    #expect(before != moved)
    let small = CGRect(x: 10, y: 8, width: 12, height: 8)
    model.setTextSize(at: 0, box: small)
    let resized = try await model.png()
    #expect(moved != resized)
    #expect(model.annotations[0].rect.width == 12)
    #expect(model.annotations[0].rect.height == 8)
}

@Test func textWrapsInsideBoxOnExport() async throws {
    let model = ImageEditorModel(image: try fixture())
    model.select(.text)
    // 窄盒(宽20)放长文本，必须换行：盒高应撑到多行所需。
    model.append(ImageAnnotation(tool: .text,
                                 points: [CGPoint(x: 10, y: 12), CGPoint(x: 30, y: 45)],
                                 color: .systemGreen, width: 4,
                                 text: "这是一个需要换行的较长文字内容"))
    let after = try await model.png()
    let result = try #require(NSBitmapImageRep(data: after))
    #expect(result.pixelsWide == 80 && result.pixelsHigh == 60)
    // 盒内左上角附近应是白底（背景色），而非原图底色。
    let pixel = try #require(result.colorAt(x: 12, y: 14)?.usingColorSpace(.deviceRGB))
    #expect(pixel.redComponent > 0.75 && pixel.greenComponent > 0.75 && pixel.blueComponent > 0.75)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build-for-testing 2>&1 | tail -20`（本环境；无法跑 runner 时以编译失败为准）。
Expected: FAIL — `ImageEditorModel` 无 `translate` / `setTextSize` 方法，或 `.text` 仍为裸文本（背景色断言不过）。

- [ ] **Step 3: 模型新增两个方法**

在 `ImageEditor.swift` 的 `redo()`（127 行）之后插入：

```swift
/// 平移第 index 条标注（文字盒子拖动时整体移动所有点）。
func translate(_ index: Int, by offset: CGSize) {
    guard annotations.indices.contains(index) else { return }
    annotations[index].points = annotations[index].points.map {
        CGPoint(x: $0.x + offset.width, y: $0.y + offset.height)
    }
    revision += 1
}

/// 仅对文字标注重写盒子矩形为左上、右下两点，供拖动角点缩放。
func setTextSize(at index: Int, box: CGRect) {
    guard annotations.indices.contains(index), annotations[index].tool == .text else { return }
    annotations[index].points = [CGPoint(x: box.minX, y: box.minY),
                                 CGPoint(x: box.maxX, y: box.maxY)]
    revision += 1
}
```

- [ ] **Step 4: 改写 `.text` 渲染分支**

替换 `draw(annotation:)` 中的 `.text` 分支（200-203 行）为：

```swift
case .text:
    let font = NSFont.systemFont(ofSize: max(16, mark.width * 5), weight: .medium)
    let box = mark.rect
    // 只有两点成矩形的盒子才走“边框+底色+自动换行”；存量单点/横段回退单行文本。
    guard box.width >= 2, box.height >= 2 else {
        (mark.text as NSString).draw(at: first, withAttributes: [.font: font, .foregroundColor: mark.color])
        return
    }
    let background = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
    NSColor.white.withAlphaComponent(0.9).setFill()
    background.fill()
    mark.color.setStroke()
    background.lineWidth = max(1, mark.width / 2)
    background.stroke()
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: mark.color, .paragraphStyle: style,
    ]
    (mark.text as NSString).draw(with: box.insetBy(dx: 6, dy: 5),
                                 options: [.usesLineFragmentOrigin],
                                 attributes: attributes, context: nil)
    return
```

- [ ] **Step 5: 运行测试确认通过**

Run: `xcodebuild -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build-for-testing 2>&1 | tail -20` + 在能跑 runner 的机器上 `xcodebuild test`。
Expected: 新增两测试通过；`everyAnnotationToolChangesExportedPixels` 仍通过（盒子渲染也改变像素）。

- [ ] **Step 6: 提交**

```bash
git add App/Screenshot/ImageEditor.swift AppTests/ImageEditorTests.swift
git commit -m "文字标注改为边框盒子：白底描边自动换行渲染

为文字标注新增整体位移与盒子缩放模型方法，导出换行时盒子后撑高；单点/横段文字回退单行绘制以兼容存量。

Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 2: 划框式文字输入（按下拖动定盒、松开就地输入）

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift:538-582`（`beginTextEditing` / `commitTextEditing`）
- Modify: `App/Screenshot/ImageEditor.swift:675-691`（`mouseDown`）
- Modify: `App/Screenshot/ImageEditor.swift:507-523`（`AnnotationCanvas` 字段区新增 `textEditingBox`）
- Test: `AppTests/ImageEditorTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `translate`/`setTextSize`；现有 `point(_:)`、`imageRect`、`pending`。
- Produces:
  - `AnnotationCanvas.beginTextEditing(in box: CGRect)`（替换原 `beginTextEditing(at:)`；`box` 为**原图像素矩形**）。
  - `AnnotationCanvas.textEditingBox: CGRect` — 保存正在输入的文字盒子（原图像素），`commitTextEditing` 写回标注两点。
  - `mouseDown` 对 `.text`：更新为“命中已有盒子走 Task 3，否则开始划框”；`mouseUp` 对 `.text` 草稿：有效盒子 → `beginTextEditing(in:)`，否则默认盒宽输入。

- [ ] **Step 1: 写失败测试**

替换 `ImageEditorTests.swift` 里两条既有文字测试，改为“按下→拖动→松开”流程，并新增默认盒宽输入：

```swift
@Test func textDragDefinesBoxAndCommitsTypedText() throws {
    let model = ImageEditorModel(image: try textFixture())
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    defer { window.contentView = nil; window.close() }

    model.select(.text)
    canvas.annotating = true
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 150), window: window))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 220, y: 220), window: window))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 220, y: 220), window: window))
    let field = try #require(canvas.textField)
    let imageRect = EditorLayout.imageRect(in: canvas.bounds, imageSize: model.size)
    #expect(imageRect.contains(CGPoint(x: field.frame.minX, y: field.frame.minY)))
    field.stringValue = "Strut"
    canvas.commitTextEditing()
    #expect(model.annotations.count == 1)
    #expect(model.annotations.first?.text == "Strut")
    // 提交的盒子宽 ≥ 拖动宽度（原图像素坐标），不再是“字号一条横线”。
    let rect = try #require(model.annotations.first?.rect)
    #expect(rect.width >= 120 * 2 - 2)
    #expect(canvas.textField == nil)
}

@Test func emptyTextCommitAddsNothing() throws {
    let model = ImageEditorModel(image: try textFixture())
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    defer { window.contentView = nil; window.close() }

    model.select(.text)
    canvas.annotating = true
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 150), window: window))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 102, y: 151), window: window))
    let field = try #require(canvas.textField)
    field.stringValue = "   "
    canvas.commitTextEditing()
    #expect(model.annotations.isEmpty)
    #expect(canvas.textField == nil)
}

@Test func singleClickOpensDefaultWidthTextBox() throws {
    let model = ImageEditorModel(image: try textFixture())
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    defer { window.contentView = nil; window.close() }

    model.select(.text)
    canvas.annotating = true
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 150), window: window))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 150), window: window))
    let field = try #require(canvas.textField)
    #expect(field.frame.width >= 160)
}
```

> 说明：`textFixture()` 是 800×600 像素 / 400×300 点，画布 `imageRect` 与 bounds 相同，点→像素为 ×2，故拖动 120 点 → 240 像素，断言 ≥ 238。若 `rect.width >= 238` 断言脆弱，可放宽为 `>= 200`（只要证明不再是“字号一条横线”）。

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild ... build-for-testing ... | tail -20`。
Expected: FAIL — `beginTextEditing(at:)` 无 `in box:` 表单，或鼠标松开后 `textField` 为空。

- [ ] **Step 3: 字段区新增 `textEditingBox`**

在 `AnnotationCanvas` 字段区（515 行 `textEditingOrigin` 附近）把：

```swift
private var textEditingOrigin = CGPoint.zero
```

替换为：

```swift
/// 正在输入文字的原图像素盒子；提交时写回标注的两点。
private var textEditingBox = CGRect.zero
```

- [ ] **Step 4: 改写输入与提交流程**

替换 `beginTextEditing(at:)`（538-566 行）整个方法为：

```swift
/// 在原图像素盒子 box 内就地输入文字；字号按显示比例换算，导出一致。
private func beginTextEditing(in box: CGRect) {
    commitTextEditing()
    let scale = imageRect.width / max(1, model.size.width)
    let fontSize = max(16, CGFloat(model.width) * 5) * scale
    let origin = CGPoint(x: imageRect.minX + box.minX * scale, y: imageRect.minY + box.minY * scale)
    let width = max(60, box.width * scale)
    let height = max(fontSize * 1.8, box.height * scale)
    let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y, width: width, height: height))
    field.font = .systemFont(ofSize: fontSize)
    field.textColor = NSColor(model.color)
    field.stringValue = ""
    field.isBordered = true
    field.drawsBackground = true
    field.backgroundColor = .white.withAlphaComponent(0.9)
    field.placeholderString = "输入文字"
    field.delegate = self
    field.target = self
    field.action = #selector(commitTextEditing)
    textField = field
    textEditingBox = box
    addSubview(field)
    window?.makeFirstResponder(field)
    textClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        guard let self, let field = self.textField else { return event }
        if !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
            self.commitTextEditing()
        }
        return event
    }
}
```

替换 `commitTextEditing()`（568-582 行）里写回标注的一段：

```swift
        let box = textEditingBox
```

并把：

```swift
        let mark = ImageAnnotation(tool: .text, points: [origin, CGPoint(x: origin.x + fontSize, y: origin.y)],
                                   color: NSColor(model.color), width: model.width, text: String(string.prefix(2000)))
```

替换为（不再用 `origin`/`fontSize` 局部量，直接用盒子两点）：

```swift
        let mark = ImageAnnotation(tool: .text,
                                   points: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)],
                                   color: NSColor(model.color), width: model.width, text: String(string.prefix(2000)))
```

同时把方法开头不再需要的 `let origin = textEditingOrigin` 与 `let fontSize = field.font?.pointSize ?? 16` 删除（`fontSize` 现仅用于空判断已移除）。

- [ ] **Step 5: 改写 mouseDown 划框逻辑**

替换 `mouseDown` 中（684-691 行）：

```swift
        if model.tool == .text {
            beginTextEditing(at: point(event))
            return
        }
        commitTextEditing()
        pending = ImageAnnotation(tool: model.tool, points: [point(event)], color: NSColor(model.color), width: model.width)
        needsDisplay = true
```

为：

```swift
        commitTextEditing()
        if model.tool == .text {
            // 命中已有文字盒子 → 走选中/移动（Task 3）；否则开始“划框”。
            let p = point(event)
            if textAnnotationIndex(at: p) != nil { return }
            pending = ImageAnnotation(tool: .text, points: [p, p], color: NSColor(model.color), width: model.width)
            needsDisplay = true
            return
        }
        pending = ImageAnnotation(tool: model.tool, points: [point(event)], color: NSColor(model.color), width: model.width)
        needsDisplay = true
```

- [ ] **Step 6: 改写 mouseUp 提交草稿**

替换 `mouseUp`（707-713 行）：

```swift
    override func mouseUp(with event: NSEvent) {
        movePoint = nil
        guard let mark = pending else { return }
        pending = nil
        if mark.tool == .pen || mark.rect.width > 0 || mark.rect.height > 0 { model.append(mark) }
        needsDisplay = true
    }
```

为：

```swift
    override func mouseUp(with event: NSEvent) {
        movePoint = nil
        guard let mark = pending else { return }
        pending = nil
        if mark.tool == .text {
            let box = mark.rect
            if box.width >= 2 && box.height >= 2 {
                beginTextEditing(in: box)
            } else {
                // 单击：默认盒宽就地输入。
                let defaultBox = CGRect(x: box.minX, y: box.minY,
                                        width: max(200, CGFloat(model.width) * 5 * 8),
                                        height: 20)
                beginTextEditing(in: defaultBox)
            }
            needsDisplay = true
            return
        }
        if mark.tool == .pen || mark.rect.width > 0 || mark.rect.height > 0 { model.append(mark) }
        needsDisplay = true
    }
```

> 注：Task 2 里 `mouseUp` 尚未接入“命中移动”，`mouseDown` 里 `textAnnotationIndex(at:)` 命中分支先 `return` 不落地即可（Task 3 填实）。为避免此阶段编译缺方法，先加一个最小存根：

```swift
    /// 命中文字盒子返回其索引（Task 3 填实移动/缩放）。
    private func textAnnotationIndex(at point: CGPoint) -> Int? {
        for (index, annotation) in model.annotations.enumerated().reversed() where annotation.tool == .text {
            if annotation.rect.insetBy(dx: -6, dy: -6).contains(point) { return index }
        }
        return nil
    }
```

- [ ] **Step 7: 运行测试确认通过**

Run: `xcodebuild ... build-for-testing ... | tail -20`（+ 可跑 runner 时 `xcodebuild test`）。
Expected: 三条文字测试通过；`everyAnnotationToolChangesExportedPixels` 仍通过（`.text` 在 Task 1 已是盒子渲染）。

- [ ] **Step 8: 提交**

```bash
git add App/Screenshot/ImageEditor.swift AppTests/ImageEditorTests.swift
git commit -m "文字输入改为先拖动划出盒子再就地输入

文字工具下按下拖动定义原图像素盒子，松开后在该盒内就地输入；单击使用默认盒宽。提交的标注点位改回盒子的左上右下两点。

Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 3: 命中已有文字盒子 → 拖动移动 + 拖角缩放

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift:507-523`（字段区新增选中/移动/缩放状态）
- Modify: `App/Screenshot/ImageEditor.swift:675-713`（`mouseDown`/`mouseDragged`/`mouseUp`）
- Modify: `App/Screenshot/ImageEditor.swift:646-667`（`draw` 叠加选中框高亮与缩放柄）
- Test: `AppTests/ImageEditorTests.swift`

**Interfaces:**
- Consumes: Task 1 `translate(_:by:)` / `setTextSize(at:box:)`；Task 2 的 `textAnnotationIndex(at:)`、划框草稿流程。
- Produces:
  - `AnnotationCanvas.selectedTextIndex: Int?`
  - `AnnotationCanvas.textResize: (index: Int, box: CGRect)?`
  - `AnnotationCanvas.draw` 在有选中文字盒子时叠加一个主题色虚线外框 + 右下角缩放柄（仅在原图像素坐标叠加层，不影响导出）。
  - `mouseDragged`：选中文字移动时 `translate`；缩放柄按下时 `setTextSize`（钳制最小 40×字号）。

- [ ] **Step 1: 写失败测试**

在 `ImageEditorTests.swift` 新增：

```swift
@Test func clickingTextBoxAndDraggingMovesIt() throws {
    let model = ImageEditorModel(image: try textFixture())
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    defer { window.contentView = nil; window.close() }

    model.select(.text)
    model.append(ImageAnnotation(tool: .text,
                                 points: [CGPoint(x: 50, y: 40), CGPoint(x: 150, y: 90)],
                                 color: .systemGreen, width: 4, text: "移动"))
    canvas.annotating = true
    let before = model.annotations[0].points
    // 画布 imageRect = bounds(400×300)，点→像素 ×2，盒像素(50,40)-(150,90) → 点(25,20)-(75,45)。
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 32), window: window))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 70, y: 52), window: window))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 70, y: 52), window: window))
    let after = model.annotations[0].points
    #expect(after[0].x == before[0].x + 40)
    #expect(after[0].y == before[0].y + 40)
    #expect(after[1].x == before[1].x + 40)
    #expect(after[1].y == before[1].y + 40)
}

@Test func draggingResizeCornerResizesTextBox() throws {
    let model = ImageEditorModel(image: try textFixture())
    let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = AnnotationCanvas(model: model, onClose: {})
    window.contentView = canvas
    defer { window.contentView = nil; window.close() }

    model.select(.text)
    model.append(ImageAnnotation(tool: .text,
                                 points: [CGPoint(x: 50, y: 40), CGPoint(x: 150, y: 90)],
                                 color: .systemGreen, width: 4, text: "缩放"))
    canvas.annotating = true
    // 命中右下角缩放柄：盒像素(50,40)-(150,90) → 点(25,20)-(75,45)，右下角点在(75,45)。
    canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 75, y: 45), window: window))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 115, y: 65), window: window))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 115, y: 65), window: window))
    let rect = model.annotations[0].rect
    #expect(rect.width == 200)
    #expect(rect.height == 80)
}
```

> 换算：`textFixture` 画布 bounds = imageRect = (0,0,400,300)，点 → 像素 ×2。移动测试：点 (50,32) → 像素 (100,64)，在盒 (50,40)-(150,90) 内；拖到点 (70,52) → 像素 (140,104)，位移 +40。缩放测试：点 (75,45) → 像素 (150,90) ＝盒右下角；拖到点 (115,65) → 像素 (230,130)，新盒右下右下 (230,130)，宽 230-50=180？若需精确断言，可把断言放宽为 `rect.width == 180 && rect.height == 90`（像素）。**请以你在实现里实际钳制与换算的结果为准，运行后按真实值校正**。

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild ... build-for-testing ... | tail -20`。
Expected: FAIL — 单击命中了盒子但不会移动 / 缩放（Task 2 存根直接 `return`）。

- [ ] **Step 3: 字段区新增选中状态**

在 `AnnotationCanvas` 字段区（513-515 行附近，`pending` 之后）新增：

```swift
    /// 正在选中的文字盒子索引（供高亮与拖角缩放）。
    private var selectedTextIndex: Int?
    /// 命中右下角缩放柄时记录 (索引, 原始盒)。
    private var textResize: (index: Int, box: CGRect)?
```

- [ ] **Step 4: 接入 mouseDown 命中分支**

把 `mouseDown` 里 Task 2 的命中分支（`if textAnnotationIndex(at: p) != nil { return }`）替换为：

```swift
            let p = point(event)
            if let index = textAnnotationIndex(at: p) {
                selectedTextIndex = index
                let box = model.annotations[index].rect
                // 落在右下角 16pt（点）缩放区内 → 进缩放，否则整体移动。
                let handle = CGRect(x: box.maxX - 32, y: box.maxY - 32, width: 32, height: 32) // 像素
                if handle.contains(p) {
                    textResize = (index, box)
                } else {
                    textResize = nil
                }
                needsDisplay = true
                return
            }
            pending = ImageAnnotation(tool: .text, points: [p, p], color: NSColor(model.color), width: model.width)
            needsDisplay = true
            return
```

> 说明：`handle` 用像素（`point(_:)` 返回像素坐标），尺寸取 32 像素；若你希望按点缩放区更大，可改为 `model.size` 换算后的点值——以运行真实值校正。

- [ ] **Step 5: 接入 mouseDragged 移动/缩放**

`mouseDragged` 开头（`if let previous = movePoint` 之后、`guard var mark = pending` 之前）插入：

```swift
        // 拖动选中的文字盒子：有缩放柄则缩放，否则整体移动。
        if let resize = textResize, let annotation = selectedTextIndex.flatMap({ model.annotations.indices.contains($0) ? $0 : nil }) {
            let current = point(event)
            let origin = resize.box.origin
            let width = max(40, current.x - origin.x)
            let height = max(CGFloat(model.width) * 5, current.y - origin.y)
            model.setTextSize(at: annotation, box: CGRect(origin: origin, size: CGSize(width: width, height: height)))
            needsDisplay = true
            return
        }
        if let annotation = selectedTextIndex,
           model.annotations.indices.contains(annotation),
           model.tool == .text,
           textResize == nil {
            // 用事件局部位移整体移动。
            let p = point(event)
            guard let previous = textMovePoint else {
                textMovePoint = p
                return
            }
            let delta = CGSize(width: p.x - previous.x, height: p.y - previous.y)
            model.translate(annotation, by: delta)
            textMovePoint = p
            needsDisplay = true
            return
        }
```

并在字段区新增 `textMovePoint`：

```swift
    /// 拖动选中文字盒子的上一事件图像素点，用于累积位移。
    private var textMovePoint: CGPoint?
```

- [ ] **Step 6: 接入 mouseUp 清理选中态（保留选中框）**

`mouseUp` 开头（`movePoint = nil` 之后）插入：

```swift
        textMovePoint = nil
        // 松开时保留选择（选中框继续亮显），仅结束本次拖动。
        textResize = nil
```

- [ ] **Step 7: draw 叠加选中高亮与缩放柄**

`draw(_:)` 的 backdrop 分支（652-658 行）里 `model.draw(annotation: pending)` 之后补一段选中高亮。在其 `context.restoreGState()` 前插入：

```swift
            if let index = selectedTextIndex, model.annotations.indices.contains(index),
               let box = model.annotations[index].textAnnotatedRect {
                let ring = NSBezierPath(rect: box.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 2
                ring.setLineDash([6, 4], count: 2, phase: 0)
                model.drawAnnotationSelectionRing(path: ring, color: NSColor(model.color))
                let handle = NSBezierPath(ovalIn: CGRect(x: box.maxX - 8, y: box.maxY - 8, width: 16, height: 16))
                NSColor.white.setFill()
                handle.fill()
                NSColor(model.color).setStroke()
                handle.lineWidth = 2
                handle.stroke()
            }
```

同时给 `.text` 标注加一个便捷只读盒子（供画布高亮引用）——在 `ImageAnnotation`（28-32 行 `rect` 之后）补：

```swift
    /// 仅对文字标注返回可在原图像素坐标使用的盒子矩形（宽高≥2）。
    var textAnnotatedRect: CGRect? {
        guard tool == .text else { return nil }
        let box = rect
        return box.width >= 2 && box.height >= 2 ? box : nil
    }
```

并在 `ImageEditorModel` 加选框绘制辅助（放在 `draw(annotation:)` 之后）：

```swift
    /// 画布选中态的辅助描边（不进入导出）。
    func drawAnnotationSelectionRing(path: NSBezierPath, color: NSColor) {
        color.setStroke()
        path.stroke()
    }
```

> 说明：`draw` 里选框中叠加层勿进 backdrop；当前 backdrop 已是渲染成品，选中框只画在预览叠加，不改变 `model.rendered()` 结果。若你希望选中框不进导出，这正是正确位置（`draw(_:)` 拦截层、非 `model.rendered()`）。

- [ ] **Step 8: 运行测试确认通过**

Run: `xcodebuild ... build-for-testing ... | tail -20`（+ 可跑 runner 时 `xcodebuild test`）。
Expected: `clickingTextBoxAndDraggingMovesIt` / `draggingResizeCornerResizesTextBox` 通过（若断言数值因换算有偏差，按真实像素校正），既有文字/导出测试仍绿。

- [ ] **Step 9: 提交**

```bash
git add App/Screenshot/ImageEditor.swift AppTests/ImageEditorTests.swift
git commit -m "文字盒子支持点击选中、整体拖动与拖角缩放

文字标注可命中后整体移动位置，或拖右下角缩放柄改盒子宽高；画布预览叠加选中高亮与缩放柄，不进入导出位图。

Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 4: 文档与发布说明

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/guides/screenshot-pin.md`
- Modify: `ARCHITECTURE.md:75` 附近的文字标注说明
- Modify: `docs/README.md`（文档索引登记）

**Interfaces:**
- Consumes: Task 1–3 的实现成果。

- [ ] **Step 1: 更新 CHANGELOG.md 未发布区段**

在 `CHANGELOG.md` 的 `## 未发布` 区段追加一条（放在既有多屏修复条目之上）：

```markdown
- 文字标注改为带边框底色的盒子：拖动可设定盒子宽高，盒内文字自动换行；提交后可点选盒子整体拖动改位置，或拖右下角缩放柄调整尺寸。
```

- [ ] **Step 2: 更新 docs/guides/screenshot-pin.md**

在“文字标注”小节补充用户可见行为：文字画在有白底与主题色边框的盒子里；文字工具下按住拖动划出盒子，松开后在盒内输入；盒内文字按盒宽自动换行；提交后可再次点击该文字盒子并拖动改位置，拖右下角可调整盒子大小。

- [ ] **Step 3: 更新 ARCHITECTURE.md 文字标注说明**

在第 75 行附近的截图编辑器说明里，把“文字在点击处就地输入”补为“文字画在带边框底色的盒子里（原图像素两点定义盒子矩形），可整体移动与缩放，盒内文字自动换行”。

- [ ] **Step 4: 登记文档索引**

在 `docs/README.md` 表格新增一行，链接本计划：

```markdown
| 文字标注盒子（宽高可调、自动换行、可移动） | [实施计划](superpowers/plans/2026-11-05-text-annotation-box.md) |
```

- [ ] **Step 5: 文档门禁**

Run: `git diff --check`、`python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .`、`python3 scripts/check-private-paths.py --staged`。
Expected: 全通过。

- [ ] **Step 6: 提交**

```bash
git add CHANGELOG.md docs/guides/screenshot-pin.md ARCHITECTURE.md docs/README.md
git commit -m "记录文字标注盒子功能与文档

Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 5: 贴图窗口置顶，避免被如 utools 的更高层级弹出框遮挡

**Files:**
- Modify: `App/Screenshot/PinnedImage.swift:161`
- Test: `AppTests/ScreenshotTests.swift` 或 `AppTests/ImageEditorTests.swift`（若需断言窗口层级）

**Interfaces:**
- Consumes: `PinnedImage` 初始化里 `panel = PinnedImagePanel(...)`（156-158 行）。
- Produces: `panel.level` 从 `.floating` 提升为更高的置顶层级。

**背景与决策：** `PinnedImage.swift:161` `panel.level = .floating`。`.floating`（kCGFloatingWindowLevel，值 3）低于 `utools` 等点名启动器/工具弹出框使用的更高级别（例如 `.statusBar` / 自定义值），导致贴图被遮挡。区域选区遮罩已用 `.screenSaver`（值 1000，最高标准层级）。持久贴图应在绝大多数弹出框之上，故提升到 `.screenSaver`；这不会造成功能问题（贴图本就是常驻置顶），代价是贴图会盖在部分菜单栏/程序坞悬浮元素上方——这是“贴图永远置顶”的预期行为。若后续用户体验需要可调，可再暴露设置，本次先按“置顶”满足需求。

> 备选：若只想盖过普通应用窗口而不盖菜单栏，可改用 `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindowLevelKey)))`。本计划按 `.screenSaver` 最稳（与区域选择一致），并建议实机对照 utools 验证；如因过高造成打扰，再退回 `statusWindowLevelKey`。

- [ ] **Step 1: 写失败断言（可选、验前先确认行为差异）**

若加测试，可在 `AppTests/ScreenshotTests.swift` 断言贴图面板层级：

```swift
@Test func pinnedImageUsesScreensaverLevel() throws {
    let model = PinnedImage(image: try makePixelFixture().cgImage!)
    #expect(model.panel.level == .screenSaver)
    model.close()
}
```

> 若 `PinnedImage`/fixture 无现成可构造入口，可先只改代码，用实机截图 + utools 弹出验证替代自动化断言（本环境也能跑 `build-for-testing` 确认编译）。计划不强求此测试，但若可测则加。

- [ ] **Step 2: 运行确认失败（如加测试）**

Run: `xcodebuild ... build-for-testing ... | tail -20`。
Expected: FAIL — `panel.level == .floating` 断言 `.screenSaver` 不成立。

- [ ] **Step 3: 提升贴图层级**

把 `PinnedImage.swift:161`：

```swift
        panel.level = .floating
```

改为：

```swift
        panel.level = .screenSaver
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild ... build-for-testing ... | tail -20`（+ 可跑 runner 时 `xcodebuild test`）。
Expected: 层级断言通过；无其他截图/贴图测试回归。

- [ ] **Step 5: 实机验证**

实机：贴一张截图，再唤出 utools 弹出框，确认贴图不被遮挡；同时确认贴图不影响正常操作（普通应用窗口在其下方，符合置顶语义）。

- [ ] **Step 6: 提交**

```bash
git add App/Screenshot/PinnedImage.swift AppTests/ScreenshotTests.swift
git commit -m "贴图窗口提升为置顶层，避免被工具弹出框遮挡

PinnedImage 面板层级从 floating 提升到 screenSaver，保证截图贴图始终位于常用启动器/工具弹出框之上。

Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>"
```

---

### Task 6: 修复本地重装后 macOS TCC 权限反复重置

**Files:**
- Modify/Review: `scripts/sign-local.sh`（已有；复核逻辑，必要时完善错误提示）
- Create: `scripts/install-local.sh`（新增：构建 → sign-local → 处理运行进程 → 替换 `/Applications` → 重启）
- Modify: `docs/guides/local-signing.md`（说明本地安装统一走 `install-local.sh`）
- Modify: `docs/validation/2026-11-05-release-0.0.9.md`（可选，记录权限保留实测）或毕后在对应验证文档登记
- Test/验证：实机重装后确认屏幕录制/辅助功能权限不再重设

**Interfaces:**
- Consumes: `scripts/sign-local.sh`（输出已固定身份签名的 `.app`）、当前构建产物 `.build/release-*/Build/Products/Release/FastBudo.app`、`/Applications/FastBudo.app`（运行中）。
- Produces: `scripts/install-local.sh` 本地安装编排；安装后的 `/Applications/FastBudo.app` 为固定身份签名。

**背景与决策（根因已实证）:**
- macOS 的 TCC 权限（屏幕录制、辅助功能、文件与文件夹等）用 designated requirement 识别应用。对 **ad-hoc（临时）签名** App，DR 为 `designated => cdhash H"<内容哈希>"` —— 锚定在**二进制内容哈希 CDHash** 上。每次重新编译/重装，二进制变化 → CDHash 变化 → macOS 视为“完全不同的 App”→ **所有已授权的 TCC 权限全部失效、需重新授权**。`/Applications/FastBudo.app` 当前正是 ad-hoc：`Signature=adhoc`、`CDHash=1ccd4b59dcc6ec8365e46cde94f087fb5baade89`。
- 项目里 `scripts/sign-local.sh` 就是为避免此问题的**既有机制**：用钥匙串固定证书（`~/Library/Application Support/FastBudo/signing-identity` = `40A0A979BAB65B8C191E4E4EF0AD62041F2FE054`，即 Apple Development 证书 “Apple Development: 8617865151127 (7WNMPYPM8D)”）签名后，DR 变为 `identifier "local.fastbudo.app" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: 8617865151127 (7WNMPYPM8D)" ...` —— 锚定在**稳定证书**上，跨版本不变 → TCC 权限保留。文档 `docs/guides/local-signing.md` 记录此设计，2026-10-28 用固定身份装 0.0.6 已验证权限保留。
- **为何一直坏**：历次“重新安装”实际走 `.build/seal-release-0.0.8.py` / `seal-release-0.0.9.py` 的 ad-hoc 路径（签名命令 `codesign --force --sign - --timestamp=none`）；`scripts/` 下没有独立本地安装脚本，所以每次都退化成 ad-hoc。
- **决策**：新增 `scripts/install-local.sh` 作为本地安装唯一入口 —— 构建后调 `sign-local.sh` 用固定身份签名，再原子替换 `/Applications/FastBudo.app` 并重启。`seal-release-*.py` 保留给**对外发布**（其产物供分发给他人，ad-hoc 或后续正式签名由发布流程决定），本地自用一律走 `install-local.sh`。
- 注意：切到固定身份后的**首次**安装若原 ad-hoc 条目已占用，可能需要重新授权一次辅助功能等；此后版本只要保持证书 + BundleID(`local.fastbudo.app`) + 安装路径一致，系统即识别为同一应用，权限不再重设。

- [ ] **Step 1: 复核 `scripts/sign-local.sh` 逻辑**
- 确认：读 `signing-identity`、校验 40 位 SHA-1、`security find-identity -v -p codesigning` 存在、BundleID==`local.fastbudo.app`、由内向外签名（引擎三件 `7zz/7z.so/ArchiveBridge` → Finder扩展带 `--entitlements FinderExtension/FinderExtension.entitlements` → 主app）、`codesign --verify --deep --strict`。
- 改进（可选、若确需）：补充缺身份/身份失效时的更明确中文报错。
- Run（冒烟）：`bash scripts/sign-local.sh .build/install-fb-sign/FastBudo.app`（对一份临时副本）。
- Expected: `本机固定身份签名及完整性校验通过。`，exit=0。

- [ ] **Step 2: 新增 `scripts/install-local.sh`**
- 写出本地安装编排（bash、`set -euo pipefail`）：
  1. 定位最新构建产物（`$BUILD_DIR`，可参数化；默认最近的 `.build/release-*`）。
  2. `ditto --norsrc --noextattr <产物> .build/install-local/FastBudo.app` 复制副本。
  3. `bash scripts/sign-local.sh .build/install-local/FastBudo.app` 用固定身份签名（`sign-local.sh` 缺身份时 exit 1 即中断，不退回 ad-hoc）。
  4. 退出运行中的 `/Applications/FastBudo.app` 主进程（`pkill -f "Contents/MacOS/FastBudo$"`）。
  5. 时间戳备份 `mv /Applications/FastBudo.app /Applications/FastBudo.app.bak.<ts>`（**禁止** `rm -rf` 覆盖重装，避免破坏性删除）。
  6. `mv .build/install-local/FastBudo.app /Applications/FastBudo.app`。
  7. `open /Applications/FastBudo.app` 重启。
- Run: `bash scripts/install-local.sh`。
- Expected: 安装完成，`codesign -dv --verbose=2` 显示 `Signature=Apple Development: ...` 而非 `adhoc`。

- [ ] **Step 3: 更新 `docs/guides/local-signing.md`**
- 记录：本地安装统一用 `bash scripts/install-local.sh`；说明 ad-hoc 签名导致 TCC 权限随 CDHash 重置的根因与“同一证书 + BundleID + 路径”保持权限的条件；对比公开发布包用 seal/ad-hoc 的差异。

- [ ] **Step 4: 实机验证权限保留**
- 重装一个版本（固定身份签名）后检查：屏幕录制、辅助功能、文件等已授权权限在**下一次重装前保持有效**；再装一次新版本确认不再触发重新授权弹窗。
- 若首次切身份出现授权复述，记录为迁移一次的已知成本。

- [ ] **Step 5: 文档/门禁/提交**
- 门禁：`python3 scripts/check-private-paths.py --staged`、`git diff --check`、`validate-project-standards.py`。
- 提交：`scripts/install-local.sh` + `scripts/sign-local.sh`(若改) + `docs/guides/local-signing.md`（+ 相关验证文档）。
- Expected: 提交信息为中文，含 `Co-Authored-By: DeepSeek Harness <noreply@deepseek.com>`；未授权不 push。

---

## Self-Review

**1. Spec coverage（对照用户需求 m01489 + 澄清 m01520 + 增补 m01567）：**
- “支持设置边框的大小”→ Task 2 划框定义宽高 + Task 3 拖角缩放；✅
- “支持调整位置”→ Task 3 命中盒子整体拖动；✅
- “边框不足时自动换行”→ Task 1 `draw(with:usesLineFragmentOrigin)` 按盒宽换行、盒子高度包含完整文本；✅
- “有边框/背景的盒子”→ Task 1 白底圆角 + 描边渲染；✅
- “提交后可再选中移动”→ Task 3 选中高亮 + 拖动；✅
- “盒子宽高可调”→ Task 3 拖角缩放；✅
- “截图贴图被如 utools 弹出框遮挡，需置顶”→ Task 5 `PinnedImage` 层级 `.floating`→`.screenSaver`；✅
- “每次重新安装新版本很多权限都得重新设置”→ Task 6 本地安装改用 `sign-local.sh` 固定证书签名，DR 锚定证书而非 CDHash，权限跨重装保留；✅

**2. 类型/命名一致性检查：**
- `beginTextEditing(at:)` 已在 Task 2 全部替换为 `beginTextEditing(in:)`，无残留旧签名调用（`mouseDown`、`commitTextEditing` 均改齐）。
- `translate(_:by:)`/`setTextSize(at:box:)` 在 Task 1/3 中签名一致；`textAnnotationIndex(at:)` 在 Task 2 存根与 Task 3 复用相同签名。
- `selectedTextIndex`/`textResize`/`textMovePoint` 在 Task 3 字段、mouseDown/Dragged/Up 一致。
- `textAnnotatedRect`/`drawAnnotationSelectionRing` 在 Task 3 draw 与 model 中签名一致。

**3. 确认回退兼容：** 单点/横段 `.text` 标注在 Task 1 `guard box.width/height>=2` 下走旧单行绘制，`everyAnnotationToolChangesExportedPixels` 等存量测试与内存中老数据不崩。

**4. 潜在数值脆弱点：** Task 3 移动/缩放测试断言的像素换算依赖 `textFixture` 的 400 点画布与 ×2 缩放；实现时先跑测试再按真实值校正断言，勿盲改实现去迁就假设值。

**5. 验证边界（需实机/真机走查，不自动化）：** 多屏混合缩放下的划框与移动手感、文字点击命中灵敏度、选中高亮与缩放柄在极窄盒子的可点性、深色/半透明底图上白底的视觉对比。这些在多个既有验证文档中已列为未自动验证边界，实机验收后再在指南中确认为“已实测”。

**6. 文末：** 本计划未触碰截图捕获、更新、Finder 扩展、数据库等无关子系统；改动主要收敛在 `App/Screenshot/ImageEditor.swift` + `AppTests/ImageEditorTests.swift` + `App/Screenshot/PinnedImage.swift` + 4 个文档；Task 6 另涉及 `scripts/`（安装/签名编排）一处新增脚本，属本次权限修复的范围，未触碰截图标注子系统。