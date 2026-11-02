---
title: 贴图拖动与响应式工具栏实施计划
status: completed
last_updated: 2026-11-02
related_spec: ../specs/2026-11-02-pinned-image-toolbar-design.md
---

# 贴图拖动与响应式工具栏 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让贴图可从图片区域直接拖动，并让所有既有功能优先以独立小按钮显示，仅在空间不足时把未显示动作收入“更多”。

**Architecture:** 保留现有 `PinnedImage`/`PinnedImagePanel` 边界，在同一文件内增加统一动作枚举、纯宽度布局策略和原生 AppKit 拖动命中层。命中层按鼠标屏幕坐标增量移动所属面板；SwiftUI 工具栏消费布局结果，直显按钮与溢出菜单复用同一动作执行入口，避免两套行为分叉。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Testing；无新增依赖，不修改 Xcode 工程结构。

**Spec:** [贴图拖动与响应式工具栏设计](../specs/2026-11-02-pinned-image-toolbar-design.md)

## Global Constraints

- 原生 SwiftUI/AppKit 实现，兼容基线保持 Apple Silicon / macOS 27，不引入 Web 壳、后端、插件框架或第三方依赖。
- 保留现有贴图变换、15% 透明度下限、菜单栏恢复、最多 10 张及合计四千万原图像素等行为。
- AppKit 窗口、SwiftUI 状态和粘贴板操作保持在主线程；不改变贴图持久化与退出释放语义。
- 只修改贴图交互、对应状态文案、测试和用户文档；不重构截图编辑器或快捷键模块。
- 实施阶段先运行 `bash scripts/build-engine.sh`；提交前按实际驱动 Agent 加入正确 `Co-Authored-By`，未取得当次推送授权不得推送。

## Review Focus

1. 宽度恰好容纳全部按钮时不得错误显示“更多”；Task 1 的阈值测试固定此行为。
2. 宽度只比完整阈值少 1 点时必须预留“更多”且动作不重复、不遗漏；Task 1 的边界与集合测试固定此行为。
3. 最小窗口、零宽度和负宽度不得产生负容量或数组越界；Task 1 的窄宽测试固定降级结果。
4. 图片拖动命中层不得覆盖工具按钮，鼠标穿透后也不得伪装仍可拖动；Task 2 的命中层测试与真实交互清单覆盖此条件。
5. 窗口缩放、图片旋转和翻转导致布局或状态变化时，按钮高亮、溢出内容与实际模型必须同步；Task 1 的状态/重算测试和 Task 3 的回归验证覆盖此条件。

---

### Task 1: 统一贴图动作并实现响应式工具栏

**Files:**
- Modify: `App/Screenshot/PinnedImage.swift:44-125`
- Test: `AppTests/ScreenshotTests.swift`

**Interfaces:**
- Consumes: `PinnedImage.resize(factor:)`、`rotate(_:)`、`transform()`、`copy()`、`opacity`、`clickThrough` 和 `panel` 的现有行为。
- Produces: `enum PinnedImageAction: CaseIterable, Hashable`；`enum PinnedImageActionEffect: Equatable { case none, showOpacity }`；`struct PinnedImageToolbarLayout`；`static func split(availableWidth: CGFloat) -> (visible: [PinnedImageAction], overflow: [PinnedImageAction])`；`PinnedImage.perform(_ action: PinnedImageAction) -> PinnedImageActionEffect`；`PinnedImage.isActive(_ action: PinnedImageAction) -> Bool`。

- [x] **Step 1: 写响应式布局的失败测试**

  在 `ScreenshotTests` 增加 `pinToolbarShowsAllActionsOnlyWhenTheyFit`、`pinToolbarReservesMoreButtonBelowFullThreshold`、`pinToolbarHandlesMinimumAndInvalidWidths`、`pinToolbarNeverDuplicatesOrDropsActions`。断言 28 点按钮、4 点间距和两侧各 8 点内边距计算出的完整阈值可显示全部 11 个动作且 `overflow` 为空；阈值减 1 点时 `overflow` 非空；240、0、负宽度都返回稳定结果；`visible + overflow` 与 `allCases` 集合完全一致且无重复。

- [x] **Step 2: 运行新增布局测试并确认失败**

  Run: `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests/pinToolbarShowsAllActionsOnlyWhenTheyFit -only-testing:FastBudoTests/ScreenshotTests/pinToolbarReservesMoreButtonBelowFullThreshold -only-testing:FastBudoTests/ScreenshotTests/pinToolbarHandlesMinimumAndInvalidWidths -only-testing:FastBudoTests/ScreenshotTests/pinToolbarNeverDuplicatesOrDropsActions`

  Expected: FAIL，提示 `PinnedImageAction` 或 `PinnedImageToolbarLayout` 尚不存在。

- [x] **Step 3: 实现动作模型和纯布局策略**

  在 `PinnedImage.swift` 定义 11 个动作及标准顺序；`PinnedImageToolbarLayout.split` 使用固定尺寸计算容量，完整容纳时不预留“更多”，存在溢出时预留一个按钮。按设计中的保留优先级选择直显动作，再按标准顺序返回两组数组。零或负宽度返回空 `visible` 与完整 `overflow`。

- [x] **Step 4: 运行布局测试并确认通过**

  Run: 使用 Step 2 的同一条 `xcodebuild test` 命令。

  Expected: 4 个新增测试 PASS。

- [x] **Step 5: 写动作执行与状态呈现的失败测试**

  增加 `pinToolbarActionsUseExistingModelBehavior` 和 `pinToolbarSelectionReflectsPersistentState`：调用 `perform` 后断言缩放范围、旋转结果、水平/垂直翻转、复制入口、穿透、隐藏与关闭仍使用既有模型行为，透明度动作返回 `.showOpacity`；断言翻转为真时 `isActive` 对应 action 为真，透明度低于 1 时透明度 action 为真，即时动作不保持选中。

- [x] **Step 6: 运行新增动作测试并确认失败**

  Run: `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests/pinToolbarActionsUseExistingModelBehavior -only-testing:FastBudoTests/ScreenshotTests/pinToolbarSelectionReflectsPersistentState`

  Expected: FAIL，提示统一执行或选中状态接口尚不存在。

- [x] **Step 7: 渲染独立按钮、透明度弹层和精确溢出菜单**

  实现 `PinnedImage.perform(_:)` 和 `isActive(_:)`，让直显按钮与“更多”菜单调用同一入口；视图收到 `.showOpacity` 后打开弹层。`PinnedImageView` 读取实际工具栏宽度并调用 `split`；每个直显动作使用 28×28 点图标按钮、中文 `.help` 与辅助功能标签。“更多”仅在 `overflow` 非空时出现且只渲染该数组。透明度 action 打开同一个 15%～100% 滑杆弹层；水平/垂直翻转及非 100% 透明度按 `isActive` 高亮，弹层打开期间透明度按钮也保持高亮。

- [x] **Step 8: 运行贴图动作与已有截图测试**

  Run: `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests`

  Expected: `ScreenshotTests` 全部 PASS；既有旋转、穿透/隐藏恢复、关闭释放和贴图预算测试无回归。

- [x] **Step 9: 在获得实施阶段提交授权后提交 Task 1**

  Run: `git add App/Screenshot/PinnedImage.swift AppTests/ScreenshotTests.swift && git commit -m "改进贴图响应式工具栏"`

  Expected: 仅包含 Task 1 的代码与测试；提交前规约检查通过并带实际 Agent 的署名。

### Task 2: 让图片区域使用原生窗口拖动

**Files:**
- Modify: `App/Screenshot/PinnedImage.swift:38-125`
- Modify: `App/Screenshot/ScreenshotController.swift:389-399`
- Test: `AppTests/ScreenshotTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `PinnedImageView` 工具栏布局和现有 `PinnedImagePanel`。
- Produces: `final class PinnedImageDragSurface: NSView`，响应 `mouseDown`、`mouseDragged` 与 `mouseUp`；`struct PinnedImageDragSurfaceView: NSViewRepresentable`；图片区域拖动命中层。

- [x] **Step 1: 写图片拖动命中层的失败测试**

  增加 `pinImageSurfaceMovesWindowFromDragEvents`：创建真实 `PinnedImagePanel` 与 `PinnedImageDragSurface`，发送按下和拖动事件并断言窗口原点按坐标增量变化。保留现有 `hiddenAndClickThroughPinsCanBeRecoveredAndClosed`，证明穿透后的恢复路径未丢失；工具栏不误拖由真实交互验收覆盖。

- [x] **Step 2: 运行拖动测试并确认失败**

  Run: `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests`

  Expected: 新测试 FAIL，窗口原点保持不变；既有恢复测试 PASS。

- [x] **Step 3: 将拖动能力限定到图片区域**

  用 `PinnedImageDragSurfaceView` 只覆盖图片内容区；surface 在按下时记录鼠标屏幕坐标和窗口原点，拖动时只按坐标增量移动所属窗口，松开后清理状态。不要覆盖工具栏、菜单或透明度弹层的命中区域，不新增移动按钮，也不改变图片模型。

- [x] **Step 4: 同步贴图成功状态文案**

  将 `ScreenshotController.pin(_:)` 的“拖动标题栏移动”改为“拖动图片移动”，继续说明菜单栏可恢复隐藏或穿透贴图。

- [x] **Step 5: 运行拖动和贴图回归测试**

  Run: `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests`

  Expected: `ScreenshotTests` 全部 PASS；图片变换、窗口关闭释放、恢复与布局测试保持通过。

- [x] **Step 6: 在获得实施阶段提交授权后提交 Task 2**

  Run: `git add App/Screenshot/PinnedImage.swift App/Screenshot/ScreenshotController.swift AppTests/ScreenshotTests.swift && git commit -m "支持从贴图图片区域拖动"`

  Expected: 仅包含 Task 2 的代码、文案和测试；提交前规约检查通过并带实际 Agent 的署名。

### Task 3: 同步用户文档并完成整体验证

**Files:**
- Modify: `docs/guides/screenshot-pin.md`
- Modify: `ARCHITECTURE.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/README.md`
- Modify: `docs/superpowers/plans/2026-11-02-pinned-image-toolbar.md`

**Interfaces:**
- Consumes: Task 1 的响应式工具栏规则与 Task 2 的图片区域原生拖动行为。
- Produces: 与实际实现一致的使用说明、架构边界、未发布变更和验证记录。

- [x] **Step 1: 更新贴图使用说明和架构边界**

  将指南中的“拖动标题栏”和固定“操作”菜单描述改为图片区域直接拖动、功能按钮优先直显、空间不足才显示“更多”、透明度按钮弹层及菜单栏恢复路径。架构文档说明宽度布局策略为纯计算、图片拖动层不修改图片模型。

- [x] **Step 2: 更新未发布变更、文档索引和计划状态**

  在 `CHANGELOG.md` 的“未发布”记录用户可见变化；保留本设计/计划在 `docs/README.md` 的索引项。实现与验证完成后把计划 frontmatter 的 `status` 改为 `completed`，勾选已执行步骤并补充真实验证边界；未完成时保持 `active`，不得写成已交付。

- [x] **Step 3: 构建固定版本第三方引擎**

  Run: `bash scripts/build-engine.sh`

  Expected: 固定版本第三方引擎构建成功。

- [x] **Step 4: 运行全量 App 测试**

  Run: `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode`

  Expected: 全部 App 测试 PASS。

- [x] **Step 5: 构建 ARM Release**

  Run: `xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build`

  Expected: `BUILD SUCCEEDED`。

- [x] **Step 6: 完成真实交互验收并记录边界**

  在真实应用中验证：图片内部拖动；按钮、菜单、透明度弹层不误拖；宽窗无“更多”；逐步缩窄时仅未直显动作进入“更多”；直显与溢出动作结果一致；穿透后从菜单栏恢复。记录显示器数量、缩放比例和未测范围，不用自动测试替代真实交互结论。

- [x] **Step 7: 运行项目治理门禁**

  Run: `python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .`

  Expected: PASS。

- [x] **Step 8: 运行隐私路径门禁**

  Run: `python3 scripts/check-private-paths.py`

  Expected: PASS，无本机用户绝对路径。

- [x] **Step 9: 检查 Markdown 相对链接**

  Run:

  ```bash
  python3 - <<'PY'
  from pathlib import Path
  import re
  import subprocess

  missing = []
  files = subprocess.run(
      ["git", "ls-files", "-co", "--exclude-standard", "--", "*.md"],
      check=True, capture_output=True, text=True
  ).stdout.splitlines()
  for name in files:
      source = Path(name)
      text = source.read_text(encoding="utf-8")
      for target in re.findall(r"\[[^]]*\]\(([^)]+)\)", text):
          if "://" in target or target.startswith("#"):
              continue
          path = (source.parent / target.split("#", 1)[0]).resolve()
          if not path.exists():
              missing.append(f"{source}: {target}")
  assert not missing, "\n".join(missing)
  PY
  ```

  Expected: 退出码 0，无缺失相对链接。

- [x] **Step 10: 检查差异格式**

  Run: `git diff --check`

  Expected: 无输出，退出码 0。

- [x] **Step 11: 在获得实施阶段提交授权后提交 Task 3**

  Run: `git add docs/guides/screenshot-pin.md ARCHITECTURE.md CHANGELOG.md docs/README.md docs/superpowers/specs/2026-11-02-pinned-image-toolbar-design.md docs/superpowers/plans/2026-11-02-pinned-image-toolbar.md && git commit -m "同步贴图交互文档与验证"`

  Expected: 文档与实际行为一致，计划状态反映真实完成度；提交前规约检查通过并带实际 Agent 的署名。

## Completion Record

- 固定第三方引擎构建成功；最终全量 App 测试为 145 项、21 个套件，全部通过；Apple Silicon Release 构建成功。
- 原计划依赖 `mouseDownCanMoveWindow` / `NSWindow.performDrag(with:)`，生产源码探针证明事件虽命中 surface，但 `performDrag` 立即返回且窗口不移动。最终改为 AppKit surface 按鼠标屏幕坐标增量移动所属面板，并以先失败后通过的窗口原点测试覆盖。
- 单显示器原生探针验证宽窗 11 个按钮直显、窄窗精确溢出、“更多”动作可执行、透明度弹层可见、翻转状态高亮；图片拖动后坐标由 `600,433` 变为 `700,383`，点击水平翻转成功且坐标不变。
- 未验证多显示器边缘与混合缩放、Intel 机器、签名安装版、菜单栏穿透恢复的真实点击链路和长期驻留；本轮未安装、未发布、未推送。
- 全库 Markdown 相对链接检查仍会报告基线中 `2026-11-02-screenshot-annotation-editing.md` 的两条既存失效链接；本次新增和修改的 6 份 Markdown 已单独检查通过，未越界改动无关历史计划。
- 后续交互调整移除原工具栏最后三个动作（穿透、隐藏、关闭），当前工具栏仅保留 8 项图片操作；本计划此前记录的 11 按钮探针结果保留为实施当时的历史证据。
