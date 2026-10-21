---
id: PLAN-20261021-performance
title: 全功能性能与内存两批优化实施计划
status: active
last_updated: 2026-10-21
related_spec: ../specs/2026-10-21-performance-design.md
---

# 全功能性能与内存两批优化实施计划

> **执行方式：** 使用 writing-plans 配套的 executing-plans 技能，按任务顺序实施和验证；不自动委派子代理。执行结果以本页状态表和验证记录为准；未勾选项保留真实的待验证范围。

**Goal:** 修复异常输入崩溃，减少主线程工作、重复计算、内存复制和后台唤醒，同时保持全部现有功能语义。

**Architecture:** 沿用现有原生模块及单连接 SQLite。先做局部修复，再通过测量决定 clone 和存储布局变更；每项独立提交，不能用削弱安全边界换性能。

**Tech Stack:** Swift 6、SwiftUI、AppKit、SQLite3、CryptoKit、ImageIO、C++ 7zip 桥接、Swift Testing、Python unittest。

**Spec:** [优化范围、证据与决策门槛](../specs/2026-10-21-performance-design.md)。[返回文档索引](../../README.md)。

## 本轮执行状态（2026-10-21）

[验证记录与五次测量](../../validation/2026-10-21-performance.md)。两批的局部优化已实施；下面的条件项没有被写成“已上线”。

| 范围 | 状态 |
|---|---|
| A1–A5 | 已实施并通过自动回归；A1 复用既有 ageText，A5 复用 show 总刷新策略而不新增 dirty |
| A6 | 文件创建已后台化；AX 迁移及真实 Finder 人工验收尚未完成 |
| B1、B4–B6 | 已实施；目录排序与分卷扫描保留，搜索采用合并请求 |
| B2 | clone 已测量但未接入；另外修复测量发现的分块复制内存累积，并新增 Tests/Performance/test_copy_memory.py |
| B3 | 编码复用已实施；数据库拆表未满足迁移/回退验证门槛，schema 保持 2 |
| 手动及重负载验证 | Intel、网络卷、AX 视图、百万条目、能耗/帧率与长期泄漏未测 |

## Global Constraints

- 保留 SwiftUI/AppKit、Swift 6、SQLite 和 7zip C++ 桥接，不新增框架或依赖。
- 实测基线为 Apple Silicon / macOS 27；Intel 和其他系统版本未验证，不声明实测兼容。
- 保留路径安全预检、O_NOFOLLOW、不可变输入快照、冲突保护、解压预算、取消及失败清理。
- 密码不得进入参数、环境变量、日志或临时文件；不得覆盖输入和已有输出。
- 压力、错误和迁移测试仅使用专用临时数据；剪贴板测试使用唯一 NSPasteboard，不读写用户剪贴板。
- 保留去重、最近使用排序、收藏保护、堆栈顺序、任意子串搜索和 v1 JSON 备份兼容性。
- 单条删除继续立即安全删除内容；数据库空间整理仅在手动清理时执行。
- 不推送、不发布、不自动修改系统权限；安装与重启不属于生成计划的授权范围。

## 执行入口与公共验证

基准 `7fdd19a`，复用工作树 `<项目工作区>`，分支 `feat/fastbudo-implementation`；实施前核对最新差异，不重置他人改动。先 A1，再 A2–A6，第一批完整验收后执行 B1–B6。A2 是 B1/B2 的回归基线，A5 是 B4/B5 的状态管理基线。B3 拆表最后独立决策，不阻塞其他项目。

所有任务先搜索函数调用方和测试，补充最小失败用例，确认失败原因后再改代码。下列命令在工作树运行；首次先构建固定引擎，涉及桥接改动后重新构建。

```bash
bash scripts/build-engine.sh
# Swift 测试命令；任务中简称 S
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
# 桥接测试命令；任务中简称 B
python3 -m unittest discover -s Tests/Bridge -v
# Release 构建命令；任务中简称 R
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
```

复用 `AppTests/ClipboardTests.swift` 的 `store()` 临时数据库模式及现有测试类。性能探针放入各模块测试文件，不加入日常应用启动路径。以同一测试在基准和优化提交上各跑 5 次；独立进程采样 RSS，记录它是否包含测试宿主。只把测试流程放进自动断言，耗时阈值用于对照评估，避免设备噪声造成 CI 偶发失败。

实施时创建 `docs/validation/2026-10-21-performance.md`，逐任务记录版本、fixture、命令、原始数据、结果与未验证项，并加入索引。本计划中的代码块是关键算法/断言示例，函数新增点均在对应任务声明，须连同调用方实现，不能视为可直接覆盖整个文件的补丁。

每项通过后按实际文件暂存并本地提交：`git commit -m "中文任务说明" -m "Co-Authored-By: Codex <codex@openai.com>"`；不执行 push。

## 第一批：确定问题与直接收益

### A1 — 异常日期入口校验及显示兜底（P1）

**文件：** `App/Clipboard/ClipboardStore.swift`、`App/Clipboard/ClipboardPanel.swift`、`AppTests/ClipboardTests.swift`。
**接口：** 保持 `importBackup(from: URL, policy: ClipPolicy) throws`；在 Panel 文件增加内部纯函数 `clipboardAgeText(used: Date, now: Date) -> String`，行视图调用它，测试可直接访问。

- [x] 添加显示断言，运行 S 确认尚无安全格式化接口；通过现有 exportBackup 生成 v1 fixture，再用 JSONSerialization 将 records[0].item.used 改为 `-1e300`，导入必须报错，原库内容与分组不变。另覆盖 created 极值、未来日期及合法边界。
```swift
#expect(clipboardAgeText(used: Date(timeIntervalSince1970: -1e300), now: Date()) == "时间未知")
#expect(clipboardAgeText(used: Date().addingTimeInterval(60), now: Date()) == "刚刚")
```
- [x] 在导入处限制 created/used 为 Unix 秒 `[0, 253402300799]`（1970 至 9999 年末）；order/queueOrder 仍单独验证 finite，不误当日期。非法记录在现有事务中抛 `ClipError.invalid`，包括与现存 ID 重复的记录。
- [x] 格式化先验证 used/now，再计算差值；异常返回“时间未知”，正常未来时间仍显示“刚刚”，之后才安全转换 Int。复用当前分钟/小时/天文案。
```swift
let stamp = used.timeIntervalSince1970
let current = now.timeIntervalSince1970
 guard stamp.isFinite, current.isFinite,
       (0...253402300799).contains(stamp), (0...253402300799).contains(current)
 else { return "时间未知" }
let seconds = max(0, current - stamp)
```
- [x] S 通过；直接调用函数覆盖 NaN、±infinity、极端有限值，避免测试进程执行会 trap 的旧 Int 转换；导入测试覆盖“有效记录后跟异常记录”的整批回滚。
- [x] 提交 `修复剪贴板异常日期导入与显示`。

### A2 — 压缩多选路径消除平方级扫描（P2）

**文件：** `App/ArchiveFiles.swift`、`AppTests/ArchiveFilesTests.swift`。
**接口：** 新增内部 `ArchiveFiles.selectedRoots(_ inputs: [URL]) -> [URL]`；`stage` 调用它，后续复制与 O_NOFOLLOW 不变。

- [x] 添加下面断言以及 `/`、`a`/`ab`、中文、大小写、不同父目录同 basename 用例，运行 S 验证失败。
```swift
let a = URL(fileURLWithPath: "/tmp/a")
let ab = URL(fileURLWithPath: "/tmp/ab")
#expect(ArchiveFiles.selectedRoots([ab, a, a.appendingPathComponent("x"), a]) == [ab, a])
```
- [x] 标准化一次，保留首次出现顺序，用 Set 去重；对每个路径沿 deletingLastPathComponent 向上查已选路径集合，根目录自等时停止。不要 resolveSymlinks、不要 lowercased、不要字符串裸前缀判断。
```swift
var seen = Set<URL>()
let unique = inputs.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
// 每项只检查祖先链；返回顺序沿用 unique。
```
- [ ] 用临时真实父子目录验证 stage 输出树；保留同 basename 冲突拒绝/保护行为及符号链接拒绝。为 helper 输入 1000/3000/10000 互不包含路径，计时只包 helper，禁止磁盘复制混入。
- [x] S、R 通过；3000/1000 耗时比应明显低于旧约 9 倍，报告路径深度及中位数，不把某台机器绝对耗时写成保证。
- [x] 提交 `优化压缩输入路径归并`。

### A3 — 大文本转换后台化并减少中间分配（P2）

**文件：** `App/Clipboard/ClipboardCapture.swift`、`ClipboardItem.swift`、`ClipboardController.swift`、`AppTests/ClipboardTests.swift`（前三者位于 `App/Clipboard/`）。
**接口：** 在 ClipPayload 新增 `func transformed(mode: ClipMode) throws -> ClipPayload`；`ClipboardCapture.write(_:to:mode:)` 调整为只提交预处理后的 payload 的 `write(_:to:)`，同时改全部调用点。NSPasteboard 仍留 MainActor。

- [x] 测试原样/纯文本/去换行/去空白；以旧算法作为语义 oracle，包含 CRLF、U+0085、U+2028、U+00A0、emoji、多 item、空文本及非文本。
```swift
let text = "甲\r\n乙\t 丙\u{00a0}丁"
#expect(try ClipPayload.text(text).transformed(mode: .lines).plainText == text.components(separatedBy: .newlines).joined(separator: " "))
#expect(try ClipPayload.text(text).transformed(mode: .compact).plainText == text.components(separatedBy: .whitespacesAndNewlines).joined())
```
- [x] 运行 S 确认缺少新接口；实现单次 plainText 解码和 unicodeScalars 单扫描：lines 中每个 CharacterSet.newlines 成员替换为空格；compact 过滤 whitespacesAndNewlines，其余模式保持既有语义。不按 Character 合并 CRLF。
- [x] copy 的 detached payload 读取后立即 transformed；主线程只写入、更新状态。转换失败不清空剪贴板；保持 copying 防重入、成功后 markUsed、堆栈消费、关闭面板语义。原有 write 测试改用先转换后写入。
- [x] S、R 通过；用唯一 NSPasteboard 验证 roundtrip；5 MB `String(repeating: "x ", count: 2_500_000)` 输出 2.5 MB，分别测纯转换/提交耗时和 RSS。20 MiB 采集检查发生在系统返回 Data 之后的限制写入验证记录，不能声称已消除此尖峰。
- [x] 提交 `减少剪贴板文本转换主线程开销`。

### A4 — 解压条目单份持有及精简响应（P2）

**文件：** `Native/ArchiveBridge.cpp`、`App/ArchiveEngine.swift`、`Tests/Bridge/test_bridge.py`、`Tests/Bridge/test_formats.py`、`AppTests/ArchiveEngineTests.swift`。
**接口：** list 模式仍返回 `{"entries":[...]}`；extract 成功返回 `{"ok":true}`，失败 JSON 和退出码保持不变。Swift 成功只检查退出状态，不依赖清单。

- [x] 搜索所有 bridge 输出解析；在 BridgeTests 增加提取成功断言，运行 B 证实旧响应不匹配。
```python
self.zip([('a.txt', b'a')])
code, result = self.run_bridge(True)
self.assertEqual(code, 0)
self.assertEqual(result, {'ok': True})
self.assertEqual((self.output / 'a.txt').read_bytes(), b'a')
```
- [x] 将 entries 的 vector move 到 ExtractCallback；解压后的元数据循环访问 callback 所有的 items；保证 COM 持有 callback 直到循环结束。列表模式保留原 items，不悬空引用、不额外复制。
```cpp
extract->items = std::move(items);
// 元数据循环改用 extract->items，extraction 在循环结束前保持存活。
```
- [x] 成功输出按 extracting 分支生成小 JSON；保留 run 的输出上限和所有路径/预算校验，不通过加大 64 MiB 上限掩盖无用输出。
- [ ] 重建引擎，B、S、R 通过；用 10000 条合成小文件测 stdout 长度、父子进程 RSS 和耗时，list 仍返回全部路径；遍历、重名、缺卷、预算和错误密码用例继续通过。
- [x] 提交 `减少解压桥接条目复制和响应体积`。

### A5 — 隐藏面板延迟刷新及合并可见列表计算（P2）

**文件：** `App/Clipboard/ClipboardController.swift`、`AppTests/ClipboardTests.swift`。
**接口：** 保持 `poll()`、`reload() async`、`show()`、`hide()`；增加私有 dirty 标志与批量赋值保护，不新建状态管理框架。

- [x] 使用现有 Controller 临时目录/唯一 board 构造方式，测 hidden capture→数据库新增、旧 items 不刷新→show 后新记录在首位；另测搜索在飞时 hide/show 和收藏、堆栈、复制排序。
- [x] 运行 S 观察隐藏状态仍刷新；poll 成功后按可见性处理，show 必须启动刷新并保留 generation 检查。
```swift
if isPanelVisible { await reload() } else { needsReload = true }
```
- [x] reload 同一结果中的 items/groups/matched 批量赋值时暂停 didSet 重算，结束仅 rebuildVisible 一次；失败保持脏标志，成功且 generation 匹配才清除。关闭时使在飞旧结果失效；保持 selected 合法及详情取消。
- [ ] S、R 通过；隐藏连续采集 100 次，在临时调试计数下确认 0 次列表查询、0 次 rebuild；show 后一次刷新。计数仅测试使用。本批不释放 items 缓存，避免顺带增加重开延迟风险。
- [x] 提交 `延迟隐藏剪贴板面板刷新`。

### A6 — Finder 新建与重命名减少主线程阻塞（P2）

**文件：** `App/AppDelegate.swift`、`App/NewItem.swift`、`App/FinderRename.swift`、`AppTests/NewItemTests.swift`。
**接口：** 保持 `NewItem.create(in:name:folder:) throws -> URL` 和 `FinderRename.revealAndRename(_:)`。后台仅创建，主线程处理成功/失败反馈与 reveal。

- [ ] 保留临时目录无覆盖、重名、非法路径测试；增加取消后不触发旧目标重命名测试及下列唯一目标断言。先复现大量冲突时主线程占用。
```swift
#expect(!FinderRename.matches([target, other], target: target))
#expect(FinderRename.matches([target], target: target))
```
- [x] AppDelegate 的 Task 内用 detached 调用同步 create，再回 MainActor reveal；catch 保持错误反馈。名称冲突策略保持不变，不把创建动作重试成多份输出。
```swift
let output = try await Task.detached(priority: .userInitiated) {
    try NewItem.create(in: directory, name: name, folder: folder)
}.value
FinderRename.revealAndRename(output)
```
- [x] AX 先探测 Finder 当前视图直接选中项属性是否能完整证明选择集；不完整必须保守失败或保留有界遍历。评估串行后台创建/查询 AX 对象，仅返回 Sendable 的 URL 集合；查询完成后仍在主线程重核 Finder PID、取消状态与唯一目标。无法证明安全则只交付后台创建并记录 AX 剩余风险。
- [ ] S、R 通过；手动用专用文件夹验证图标/列表/分栏视图、多选、切换前台、连点新建、未授权及繁忙 Finder。网络卷未实测则明确记载；timeout 不当作绝对硬上限。
- [x] 提交 `降低 Finder 新建操作主线程阻塞`。

## 第二批：进一步优化及测量决策

### B1 — 解压目录与分卷准备

**文件：** `App/ArchiveEngine.swift`、`App/ArchiveFiles.swift`、`AppTests/ArchiveEngineTests.swift`、`AppTests/ArchiveFilesTests.swift`、`Tests/Bridge/test_formats.py`。
**接口：** 保持 extract；family 目标值只计算一次。children 默认仍排序；确需无序时新增默认 `sorted: Bool = true` 参数，调用方逐个判断。

- [ ] 在临时目录放 10000 个无关文件与真实分卷 fixtures，记录准备耗时；覆盖 `.rar/.part1.rar/.r00`、`.zip/.z01`、`.001`、`.tar.gz` 和普通 `._notes`。
- [x] 将目标 family 提到 filter 外；ZIP/RAR 的普通后缀也可能是分卷入口，不能仅按后缀跳过兄弟扫描。只有格式和桥接行为证明不依赖邻居的输入才能快照自身。
```swift
let targetFamily = family(filename)
let related = try ArchiveFiles.children(input.deletingLastPathComponent()).filter {
    $0.lastPathComponent == filename || family($0.lastPathComponent) == targetFamily
}
```
- [x] 先只消除重复正则；无序遍历须证明输出冲突和错误顺序不受影响再启用。逐项 DIR 枚举只有测出数组内存瓶颈才做，并用 defer 关闭句柄，覆盖取消/读取失败。
- [x] B、S、R 通过；相同 fixture 结果/元数据不变，准备中位数和 RSS 记录；缺卷仍失败且不保留半成品。
- [x] 提交 `减少解压准备重复目录处理`。

### B2 — APFS clone 快照收益实验及条件实施

**文件：** `App/ArchiveFiles.swift`、`AppTests/ArchiveFilesTests.swift`、性能验证记录；不改用户配置。
**接口：** 保持 stage 的公开签名和现有复制 fallback；只优化普通文件快照的数据复制步骤。

- [x] 用临时 1 GiB 文件、10000×4 KiB 小文件，对当前复制测 5 次。记录卷类型、物理分配字节及缓存条件，禁止仅用稀疏文件宣称真实复制收益。
- [x] 单独实验系统 clone API；核实官方平台 API 的符号链接、排他创建、元数据及并发修改语义。保留现有 nofollow/fstat 输入身份与变更检查；失败仅在目标可安全清理且允许回退时走普通复制。
- [x] 加快照隔离断言：修改源文件后快照仍为旧数据；反向修改快照不得改变源，取消/空间不足/源替换测试只能用临时文件。
```swift
try Data("after".utf8).write(to: source)
#expect(try Data(contentsOf: snapshot) == Data("before".utf8))
```
- [ ] 在不支持 clone 的测试卷或可控失败路径验证 fallback。达到 spec 的 20% 收益和安全门槛才接入；未达到则删除实验代码，仅提交测量结论。tar.gz 中间 tar 保留。
- [x] 若接入则 S、B、R 全通过后提交 `优化文件快照复制`；否则提交 `记录快照复制优化评估`。

### B3 — 编码复用与数据库布局条件优化

**文件：** `App/Clipboard/ClipboardStore.swift`、`AppTests/ClipboardTests.swift`、性能验证记录；若拆表实施，同步 `docs/guides/clipboard.md`。
**接口：** capture/reply/importBackup 外部接口不变；内部 put 支持传入已验证编码与哈希，不跳过公开入口校验。

- [ ] 比较 1/10 MiB 文本的新增、重复采集、markUsed、收藏、导入；测试重复内容 ID 一致、最近使用更新、收藏/堆栈保护及备份往返。
```swift
let a = try db.capture(.text("重复"), source: "Tests", policy: .standard)
let b = try db.capture(.text("重复"), source: "Tests", policy: .standard)
#expect(a == b)
#expect(try db.list().count == 1)
```
- [x] capture 中保留一次 validate/encoded/SHA256，将 Data/hash 传给私有写入路径；reply/import 仍自行验证。所有来源使用 sortedKeys 编码，禁止改变去重哈希规则。先独立 S、R 验证并提交 `复用剪贴板写入编码结果`。
- [ ] 重测 markUsed 的延迟、独立进程 RSS、数据库写入量；仅当大行搬运仍为显著成本时做 schema 3 实验：保留 clips 元数据、search/hash/bytes，把 payload 放入按同 UUID 关联的内容表；所有读、删、去重、清理、导入/导出在事务内同步处理两表。
- [ ] 迁移事务内复制并核对条数/内容哈希，最后更新版本；在复制中途注入失败，重启后必须仍能读完整旧库。不兼容旧程序时明确拒绝旧版写入；回退使用迁移前一致性备份，不能静默丢失迁移后数据。若无法交付可靠回退，停止拆表。
- [ ] 通过 spec 的 20% 门槛以及 v2→v3、空库、重复数据、失败回滚、v1 JSON 兼容测试才独立提交 `分离剪贴板内容与元数据存储`；否则保持 schema 2，记录不实施原因。

### B4 — 合并过期搜索工作

**文件：** `App/Clipboard/ClipboardController.swift`、`App/Clipboard/ClipboardStore.swift`、`AppTests/ClipboardTests.swift`。
**接口：** 保留 `matchingIDs(_ query: String) throws -> Set<UUID>` 和现有 substring SQL；Controller 同时只运行一个搜索，保留一个最新待执行 query。

- [ ] 构造 1000 条合成记录，快速输入 20 次；测最终结果、完成查询次数和期间采集等待。加入中文、emoji、字面 `%_` 断言。
```swift
let id = try db.capture(.text("中文 %_"), source: "Tests", policy: .standard)
#expect(try db.matchingIDs("%_") == [id])
#expect(try db.matchingIDs("中文") == [id])
```
- [x] 保留 180 ms 去抖；已有搜索执行时只覆盖最新请求，完成后检查 query/generation，再运行最新请求。清空搜索、hide、reload 和 stop 都要使旧结果失效。已开始查询最多残留一个，不宣称即时取消。
- [x] 先测此简单方案；若仍需 SQLite progress handler，单独在持锁的查询作用域安装/移除，以该查询专属取消状态终止，`defer` 清理；禁止从任意 UI Task 对共享连接调用全局 interrupt。
- [x] S、R 通过；连续搜索期间 capture/import/update 不被误取消，最终结果正确；记录查询次数和写入最长等待。只有查询实际取消才将其描述为“取消”。
- [x] 提交 `合并剪贴板过期搜索请求`。

### B5 — 暂停采集时停止轮询

**文件：** `App/Clipboard/ClipboardController.swift`、`AppTests/ClipboardTests.swift`。
**接口：** start/stop/setEnabled/configureShortcut 保持；私有 timer 生命周期与 hotKey 生命周期分开，采集间隔仍 0.5 秒。

- [x] 用唯一 board 测 start 两次、暂停、暂停期间复制、恢复、恢复后新复制；热键启用状态不随采集暂停改变。运行 S 记录旧版暂停仍唤醒。
- [x] setEnabled(false) invalidate timer 并置 nil；恢复先 lastChange=board.changeCount 再建 timer，tolerance=0.1；start 即使采集关闭也配置热键，stop 同时停止两者。
```swift
timer?.invalidate()
timer = nil
// 恢复时先更新 lastChange，再创建唯一一个采集 timer。
```
- [x] 暂停时拒绝新 capture；明确已经开始的持久化允许完成，避免取消事务造成半写入。轮询首个 guard 先检查 enabled，且防重复 timer。
- [ ] S、R 通过；暂停 60 秒采样确认无采集 timer 回调，恢复后新内容仅一条，暂停期间旧内容不补采。手动验证快捷键仍能打开已有历史。
- [x] 提交 `暂停剪贴板采集轮询以减少唤醒`。

### B6 — 限制归档结果历史

**文件：** `App/ArchiveModel.swift`、`AppTests/ArchiveQueueTests.swift`；核对 `App/FastBudoApp.swift` 的 results.first 调用，无须改 UI。
**接口：** results 仍为 `[URL]`，最近项在前，最多 20 个；pending、failed、重试 FIFO 不变。

- [x] 追加 21 个专用临时小文件归档任务，等待队列完成，断言 results.count=20、first 是最后完成项，所有 21 个磁盘输出都存在；先跑 S 观察 count 失败。
- [x] 在成功插入结果后裁剪尾部，不增加配置或持久化。
```swift
results.insert(result, at: 0)
if results.count > 20 { results.removeLast(results.count - 20) }
```
- [x] 运行 S；现有两任务顺序测试保持通过；失败任务不占结果历史，重试完成仍插在最前。
- [x] 执行 R，并记录此项只是消除无界增长，不宣称显著降低常驻内存。
- [x] 提交 `限制归档任务结果历史数量`。

## 每批验收与交付

- [ ] 第一批结束以及第二批结束分别执行引擎构建、B、S、R；只有生成源文件或工程配置变化时才运行 XcodeGen，并纳入生成工程。
- [ ] 更新性能验证记录：每项至少 5 次同条件测量、是否达标、保留或放弃的方案及原因；注明未测 Intel、网络卷、百万条目或长期泄漏，不复用旧测试数冒充本次结果。
- [ ] 用专用 fixtures 验证 ZIP/7z/tar.gz、元数据过滤/恢复、缺卷、密码、取消、不覆盖、Finder 新建、复制去重/置顶/收藏/堆栈/回复、备份回滚、暂停和热键。手动验证依赖权限，不自动授予。
- [ ] 更新计划复选框；条件优化未采用标记“评估完成、未实施”，不误写成功落地。维护 spec/plan/验证记录双向链接与 docs 索引。
- [ ] 执行文档门禁及 `git diff --check`，审查无密码/用户内容进入日志；本地提交验证记录，不推送。
```bash
python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .
git diff --check
```
- [ ] 交付代码、测试证据和残余限制。若后续获准安装：先保存当前可运行包，核验签名、Finder 扩展标识及 entitlements，正常退出再替换，启动后验证右键入口和数据库；schema 迁移回退必须使用一致性备份，安装失败保留旧包。此步骤不包含 GitHub 发布。
