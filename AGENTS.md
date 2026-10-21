# FastBudo 项目规则

## 先读哪里

- 构建、使用和用户可见边界：[README](README.md)。
- 模块职责、线程模型、数据流与持久化：[架构文档](ARCHITECTURE.md)。
- 版本范围及发布准备：[变更日志](CHANGELOG.md)；未发布条目不代表已发布版本。
- 设计、计划、测试证据：[文档索引](docs/README.md)。历史方案须与当前代码核对。

## 技术与安全约束

- SwiftUI/AppKit macOS 应用，原生桥接位于 Native/ArchiveBridge.cpp；不新增 Web 壳、后端或插件框架。
- 当前兼容基线为 Apple Silicon / macOS 27；其他版本必须实测后再声明。
- [文档索引](docs/README.md) 是设计、实施计划和验证记录入口。
- 先执行 `bash scripts/build-engine.sh` 构建固定版本第三方引擎，再执行 Xcode 构建或测试。
- project.yml 是 Xcode 工程配置源；更改后运行 XcodeGen 并提交生成工程。保留 Xcode 构建脚本沙箱设置。
- 不解析 7zz 人类可读列表作为路径安全边界；条目枚举与解压通过结构化桥接。
- 密码不得进入参数、环境变量、日志或临时文件。不得覆盖输入和已有输出，不自动改变系统打开关联。
- Vendor/7zip 源码包、许可证、来源及 SHA-256 保持一致；修改第三方源码必须记录并履行许可义务。
- 治理文档变更后运行 `python3 ~/.codex/skills/ai-project-standards/scripts/validate-project-standards.py --root .`；退出码非零阻断交付。
- 用户文件不能作为破坏性测试样本；失败、取消、空间不足测试只使用专用临时数据。


## 修改时保持的不变式

- 归档任务串行执行，工作目录与输出排他创建；失败或取消只清理本任务拥有的临时内容。
- Finder 扩展只构造请求；主应用必须校验外部请求。新建使用排他创建，不能覆盖现有文件。
- AppKit 粘贴板与 UI 操作留在主线程；数据库、文件复制和纯文本转换避免阻塞主线程。
- 剪贴板过期查询不能覆盖新状态；复制后的最近使用顺序与用户手动排序保持独立。
- 维持内容去重、按需详情和有界缓存；暂停采集时停止轮询，隐藏面板时避免无用列表刷新。
- 修改数据库或备份格式时验证旧数据兼容与失败回滚；单条删除不执行 VACUUM。
- 性能结论注明环境、样本和测量方法；独立探针不能代替真实应用常驻内存、帧率或长期泄漏验证。

## 验证

先构建引擎，再按改动范围运行：

```bash
bash scripts/build-engine.sh
python3 -m unittest discover -s Tests/Bridge -v
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
python3 -m unittest discover -s Tests/Performance -v
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
```

- 归档或桥接变更检查 Bridge 与 App 测试；复制内存相关变更加跑 Performance 测试。
- 空间不足测试使用 `python3 scripts/test-low-space.py` 的独立磁盘映像，禁止填满用户主盘。
- Finder 菜单、辅助功能权限与窗口生命周期需要真实系统交互验证；未验证必须写明。
- 仅文档变更运行文档门禁、相对链接检查和 `git diff --check`，无需重跑应用测试。

## 文档与发布

- 架构变化同步架构文档；用户可感知变化写入变更日志的未发布部分，并在文档索引登记新文档。
- 不把未落地原型或条件优化写成已上线能力；验证记录保留未测范围。
- 发布时核对主应用与 Finder 扩展的版本号、构建号以及安装包架构、签名和公证状态。
- Git 推送、打发布标签与上传安装包按当次用户授权执行；“未发布”日志本身不构成发布授权。
