---
title: 0.0.6 本地安装、更新源与区域原位编辑验证
status: active
last_updated: 2026-10-29
---

# 更新源与区域原位编辑验证

最新决定：用户要求沿用当前 `lliony/fastbudo` 私有仓库并本地重装。以下公开候选清单为历史准备记录，附件目标地址已过期，不得发布。独立公开仓库方案取消。

返回[索引](../README.md)。关联更新源[设计](../superpowers/specs/2026-10-28-public-updates-design.md) / [计划](../superpowers/plans/2026-10-28-public-updates.md)，原位编辑[设计](../superpowers/specs/2026-10-28-inline-capture-design.md) / [计划](../superpowers/plans/2026-10-28-inline-capture.md)。

最新代码已整合至主分支，见[2026-10-29 整合验证](2026-10-29-screenshot-main-integration.md)。以下未提交、未推送描述均为各次实施时的历史状态，安装包尚未正式发布。

## 沿用当前仓库及本地安装

2026-10-28：ReleaseSource 与测试 fixture 改回 `lliony/fastbudo`，继续复用统一来源和 404 分类。相关 UpdateChecker / UpdateInstaller 测试、ARM Release 构建、固定身份签名及安装产物隐私检查通过。未改变仓库可见性、未创建发行仓库、未上传。

旧版正常退出并备份到 `~/Library/Application Support/FastBudo/AppBackups/20261028-191023/FastBudo.app`；安装至 `/Applications/FastBudo.app`。实际启动设置页显示 0.0.6；屏幕录制已启用，权限设置按钮隐藏；截图 Option+1、贴图 Option+3、快速复制 Option+2、快速下载 Option+4 均保留且显示已注册。未修改用户偏好。

当前仓库仍私有，匿名在线更新访问限制没有解决。本轮未重新执行真实多屏抓图或 Intel 构建；此前独立公开源双架构候选包已标记失效，不能作为此次本地安装证据。


## 本地安装前的实现与验证

2026-10-28，Apple Silicon / macOS 27、Xcode 27 环境。匿名原私有源 API 返回 403 限流、官网返回 404；登录查询确认源码仓库私有且已有 v0.0.5。后续取消新发行源方案，当前私有仓库的匿名访问限制仍存在。

ReleaseSource 统一所有检查和下载地址；404 分类保留错误状态，不误报最新。区域截图隐藏并保留选区面板，抓图后转交编辑器；保留 100ms 隐藏等待，不是冻结屏幕方案。取消、失败及停止释放未转交窗口；快速输出失败回到原位编辑。

- 固定引擎构建通过。新增面板接口测试先出现预期编译失败；实现后全量 120 项 / 21 套测试通过。
- 加入最终面板身份与取消释放测试后，Screenshot / ImageEditor / UpdateChecker / UpdateInstaller 共 50 项 / 4 套回归通过。
- ClipboardLifecycle 独立顺序验证冷启动、设置关闭、已有设置窗口三个场景通过。
- ARM 与 Intel Release 构建成功；Intel 使用 x86_64 和最低 macOS 14 构建引擎与应用，完成后本地引擎恢复 arm64。
- 双包解包后签名完整性、用户目录隐私扫描通过；主应用、扩展、7zz、7z.so、ArchiveBridge 架构及最低系统一致，版本均为 0.0.6 / 6。

## 原生交互证据及未测范围

隔离探针使用生产选区/控制器/编辑器，实际拖选后填充合成图，记录 sameWindow=true；选区与编辑窗口均为 (300,480,600,360) 点，图像仍为 1200×720 像素；实际看到原位图片及右下角工具，Escape 关闭成功。探针不抓取屏幕，不申请录制权限。

极小图实际 UI 操作因前台应用切换中断，未完成验收；几何自动测试已覆盖。真实截图是否含遮罩、混合缩放多屏、完整输出 UI、Intel 硬件尚未验收。未修改归档/复制路径，未重跑 Bridge 与 Performance 专项。此阶段尚未安装；后续已完成本地安装，未提交、推送或公开发布。没有更高正式版本，未测试完整自动升级替换链路。

## 已失效的历史候选包清单

本地目录 `.build/public-release-0.0.6/` 是已取消方案的历史产物，包内仍指向 lliony/fastbudo-releases，不得用于当前安装或发布。RELEASE-NOTES.md 已标记失效，binary-checks.json 仅作历史留证；下列大小与校验和不代表当前安装构建。

| 附件 | 字节数 |
|---|---:|
| `FastBudo-0.0.6-macOS-arm64.zip` | 4855021 |
| `FastBudo-0.0.6-macOS-x86_64.zip` | 5066758 |
| `FastBudo-0.0.6-third-party-source.tar.gz` | 1574630 |
| `SHA256SUMS.txt` | 302 |

ARM 最低 macOS 27，Intel 最低 macOS 14；固定本机身份签名，未公证。第三方源码包仅公开许可要求的引擎、桥接及重建材料，不含 Swift 应用源码或 Git 历史。校验值如下：

```
af4543a304bb0c1dc6ba2e90359606cd70331422b5fc750390023668bc1912cd  FastBudo-0.0.6-macOS-arm64.zip
cbbe6482f1fcfb3968a9afc4fcfd0c2fae4c2c9acf728968200361ea7f7cc2a5  FastBudo-0.0.6-macOS-x86_64.zip
d3c9c546988adc2673cb44d02807e3f9f1c70de221a1ff58acc6c07971956f89  FastBudo-0.0.6-third-party-source.tar.gz
```


## 选区明亮与外围灰显修正

2026-10-28：用户指出图片仍像浮层。根因是面板虽复用，但编辑阶段缩成选区尺寸且移除了外围遮罩。新增回归先复现窗口尺寸与阴影两项失败；修复后保留整屏面板，在选区外绘制 18% 黑色遮罩并保留选区边界，工具在选区右下角。拖动只移动选区与工具，原图导出仍不包含遮罩或控件。

生产源码合成图探针记录 sameWindow=true，面板保持 (0,0,3432,1080)，选区初始为 (300,480,600,360) 点、原图为 1200×720 像素。实际查看外围持续灰显、图片原位与工具；拖动后外围不移动，保存面板打开与取消、Escape 退出通过。探针不读取真实屏幕，真实抓图是否包含遮罩及混合缩放多屏仍未验收。最终 ScreenshotTests / ImageEditorTests 共 30 项通过，ARM Release 构建、固定身份签名与安装包隐私扫描通过。已备份前一构建至 ~/Library/Application Support/FastBudo/AppBackups/20261028-201140-shade/FastBudo.app，并更新本地 0.0.6；重启后实际设置页显示屏幕录制已启用，四个 Option 快捷键仍注册成功。本次未重新构建 Intel 包、未发布。


## 区域截图入口固定等待修复

2026-10-28：检查当前代码及已有提交 769f101，确认当前截图开发分支仍无该启动修复，安装构建继续执行 350ms 固定等待。本次复用其模式分支及真实选区可见性回归；三个区域动作修复前均在 150ms 观察上限内未显示选区。仅区域模式跳过入口等待，保留选区确认后的遮罩移除间隔。


修复后 ScreenshotTests 23 项通过，三个动作实测调用到选区可见为 20.05 / 22.11 / 20.69ms，仅表示本机测试环境的应用内响应。ARM Release、固定身份签名及隐私检查通过。已备份前构建至 ~/Library/Application Support/FastBudo/AppBackups/20261028-202040-immediate/FastBudo.app，重新安装本地 0.0.6。实际设置页确认录制权限与快捷键注册保留，按钮进入区域选取、Escape 取消正常。CUA 定向发送 Option+1 未观察到全局入口触发，因此不以该操作作为物理快捷键响应验收；没有测量物理键盘到屏幕的延迟。
