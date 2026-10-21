---
title: 两批性能优化实施验证
status: active
last_updated: 2026-10-21
related_plan: ../superpowers/plans/2026-10-21-performance.md
related_spec: ../superpowers/specs/2026-10-21-performance-design.md
---

# 两批性能优化实施验证

[返回索引](../README.md) · [计划](../superpowers/plans/2026-10-21-performance.md) · [五次测量原始数值](data/2026-10-21-performance.json)

## 范围与环境

基准 `7fdd19a`；2026-10-21，arm64 / macOS 27.0.1（26A434）。沿用既有工作树和顺序执行方式。代码没有新增依赖、修改 schema、安装应用或推送。性能探针使用 `swiftc -O`，应用另做 Release 构建；临时文件及唯一 NSPasteboard 均为合成内容。

## 两批落地情况

| 任务 | 结果 | 验证及边界 |
|---|---|---|
| A1 日期 | 已修复 | 复用 ClipboardRow.ageText；导入日期限制到 1970–9999 年，旧库异常值安全显示；整批回滚测试先失败后通过 |
| A2 多选路径 | 已优化 | Set 去重、沿祖先链排除子路径；保留首次顺序，真实父子文件复制、根目录、中文、大小写及前缀边界通过 |
| A3 文本转换 | 已优化 | 后台校验和 Unicode scalar 扫描，主线程只提交剪贴板；多 item、CRLF、Unicode 空白、富文本/图片及复制行为通过 |
| A4 桥接 | 已优化 | 条目 vector move；提取返回 12 字节状态，list 保持清单；19 项安全/格式测试通过 |
| A5 隐藏刷新 | 已优化 | 隐藏采集只入库，show 总是刷新，不另增无用 dirty 字段；快照赋值只计算一次 visible；保留列表缓存 |
| A6 Finder | 部分落地 | 创建文件转 detached；原地重命名仍保留现有 AX 验证，未改变系统权限，未完成真实 Finder 各视图人工验收 |
| B1 解压准备 | 已做局部优化 | 目标 family 仅计算一次；仍扫描分卷邻居并保留排序，未把 ZIP/RAR 当作必然单卷 |
| B2 快照 | 评估完成，clone 未采用 | 原型会携带 xattr，缺少过滤及不支持卷回退验证；保留普通复制，但修复了本次测量发现的自动释放池累积 |
| B3 存储 | 编码复用已落地，拆表未采用 | 新内容只编码/哈希一次；schema 2、v1 备份及安全删除保持；迁移和回退安全门槛尚未满足 |
| B4 搜索 | 已优化 | 一个在飞读取任务、一个最新请求，保持 180 ms 去抖及任意子串语义；不使用共享连接 interrupt，已开始的查询不会即时中断 |
| B5 暂停轮询 | 已优化 | 暂停 invalidate timer；恢复先更新 changeCount；start/stop 幂等、热键独立，tolerance 0.1 秒 |
| B6 结果历史 | 已优化 | 最多 20 个内存 URL；21 个归档的磁盘文件全部保留，任务 FIFO 不变 |

A5/B4 集成时全量测试捕获“show 后立即 copy”被旧查询覆盖排序的竞态。复制持久化后使旧快照失效；仅在有在飞查询或条目未加载时再同步。`ClipboardInteractionTests` 用 `-test-iterations 5` 复验通过。

## 测量结果

每组 5 次，表中为耗时中位数；峰值 RSS 也是五个独立进程峰值的中位数，**不是主应用常驻内存**。冷热缓存、进程启动和并行系统负载均会影响结果；完整样本包含异常值，不移除慢样本。

| 合成场景 | 之前 | 之后 | 内存/输出说明 |
|---|---:|---:|---|
| stage：1000 个不存在路径，首次 I/O 失败前准备 | 686.1 ms | 29.7 ms | 不包含真实内容复制；此组未保留 RSS |
| stage：3000 个不存在路径 | 6135.1 ms | 293.3 ms | 优化后样本 113–483 ms 波动大，不用于严格复杂度拟合 |
| 5 MB 文本去空白并写唯一剪贴板 | 121.4 ms | 53.9 ms | RSS 114.36 → 33.03 MiB，输出均 2.5 MB |
| 10000 条目 ZIP 提取 | 1830 ms | 1780 ms | RSS 15.41 → 15.06 MiB；stdout 568904 → 12 字节，主要收益是移除无用输出 |
| 10000 邻居名字 family 比较 | 78.4 ms | 38.5 ms | 只测名称处理，不代表完整解压耗时 |
| 10 MiB 文本首次采集，含进程及数据库创建 | 207.2 ms | 181.5 ms | RSS 都约 126.12 MiB；之后首次运行 2110 ms，已保留，不宣称消除采集峰值 |
| 1 GiB 普通快照复制 | 1204.7 ms | 791.8 ms | RSS 1035.09 → 9.11 MiB，采用每块 autoreleasepool |
| 10000×4 KiB 文件普通快照 | 1958.2 ms | 1892.7 ms | RSS 51.97 → 12.31 MiB |

路径 helper 另测 1000/3000/10000 项耗时 4.8/23.6/74.0 ms，仅单次检查，不与上表 stage 五次结果混用。没有对真实滚动帧率、UI 主线程 P95/P99、暂停能耗或长期泄漏做定量结论。

## 新发现的分块复制内存缺陷

FileHandle.read 的桥接缓冲在外层自动释放池排空前存活。原实现虽然每次只读 1 MiB，长任务仍可能累计整个输入大小；独立 256 MiB 输入回归在修复前峰值 276955136 字节，超过 128 MiB 门槛而失败。每块增加 autoreleasepool 后峰值 9519104 字节，内容逐块比对一致；不改变文件打开方式、取消检查或元数据策略。

复现命令（macOS/Xcode 工具链）：

```bash
python3 -m unittest discover -s Tests/Performance -v
```

测试自己创建临时目录、实际写入 256 MiB 文件、编译生产 ArchiveFiles.swift、调用真实 stage，用 `/usr/bin/time -l` 采集独立进程 RSS，再比较完整输出。无需读取用户文件或运行安装版应用。

## 条件方案为什么未采用

**APFS clone：** Apple SDK 自带 `clonefile(2)` 与 `copyfile(3)` 明确 clone 会复制扩展属性；fcopyfile 的 CLONE 还会退回普通复制。原型使用 fclonefileat，1 GiB 文件耗时中位数 0.45 ms，10000 小文件 1271.9 ms；修改源文件后快照保持旧内容，但 `com.fastbudo.test` 属性也出现在快照中。这个原型不满足默认去元数据要求，且未验证非支持卷回退、属性剥离失败与空间不足路径，因此未接入。原型数字不作为生产版本性能承诺；本轮采用低风险的分块释放修复。

**数据库拆表：** 当前 10 MiB 单条记录连续 20 次 markUsed 中位数 586.4 ms，进程峰值约 104.8 MiB，说明大行成本仍在。编码复用不解决这个问题。拆表会同时影响删除、去重、导入导出与旧版读取；本轮未完成 schema 3 迁移故障注入和一致性回退验证，也未交付拆表后的对照数据，不能声称达到 20% 收益及安全门槛。为避免升级用户数据格式，保持 schema 2；这是尚未落地的候选，并非“没有优化空间”。

**AX 后台迁移：** 保留唯一选择集与前台 PID 核对。尚未证明直接属性在 Finder 各视图都完整，也未实测后台 AX 的线程与时序，因此没有放松核验或用 unchecked Sendable 绕过约束。

## 自动验证与已知限制

- 第一批：56 项应用测试、19 项桥接测试、Release 构建通过。
- 最终代码：59 项应用测试（16 个 suite）、19 项桥接测试、1 项独立进程内存回归全部通过，Release 构建通过；文档门禁与 git diff --check 通过。
- 最终执行命令：`bash scripts/build-engine.sh`；`python3 -m unittest discover -s Tests/Bridge -v`；`python3 -m unittest discover -s Tests/Performance -v`；`xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode`；同目标的 `xcodebuild -configuration Release build`。
- 新增回归覆盖：极端日期回滚、日期显示溢出、路径归并、Unicode 转换、精简桥接响应、隐藏采集、快速搜索/清空、暂停恢复、历史上限与磁盘文件保留、独立进程大文件内存。
- 既有测试在 SQLite 连接存活时删除临时目录会打印 vnode unlinked 警告，基线也存在；不是用户数据库损坏的证据。坏图片及不存在的合成 file URL 测试也有预期系统日志。
- 未实测：Intel、macOS 26、网络卷、百万条目、长时间运行泄漏、真实滚动帧率、断电、磁盘耗尽、Finder 各视图及系统热键人工验收。暂停功能有恢复行为测试，未做 60 秒能耗采样。
- 单条 20 MiB 限制仍在 NSPasteboard 返回 Data 后检查，无法防止来源提供超大数据时的瞬时系统分配。
- 保留工作树，不自动安装、重启、合并、推送或发布。
