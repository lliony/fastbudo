# FastBudo 项目规则

- SwiftUI/AppKit macOS 应用，原生桥接位于 Native/ArchiveBridge.cpp；不新增 Web 壳、后端或插件框架。
- 当前兼容基线为 Apple Silicon / macOS 27；其他版本必须实测后再声明。
- [文档索引](docs/README.md) 是设计、实施计划和验证记录入口。
- 先执行 `bash scripts/build-engine.sh` 构建固定版本第三方引擎，再执行 Xcode 构建或测试。
- 自动验证：`python3 -m unittest discover -s Tests/Bridge -v`；`xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode`。
- project.yml 是 Xcode 工程配置源；更改后运行 XcodeGen 并提交生成工程。保留 Xcode 构建脚本沙箱设置。
- 不解析 7zz 人类可读列表作为路径安全边界；条目枚举与解压通过结构化桥接。
- 密码不得进入参数、环境变量、日志或临时文件。不得覆盖输入和已有输出，不自动改变系统打开关联。
- Vendor/7zip 源码包、许可证、来源及 SHA-256 保持一致；修改第三方源码必须记录并履行许可义务。
- 治理文档变更后运行 `python3 /Users/ly/.codex/skills/ai-project-standards/scripts/validate-project-standards.py --root .`；退出码非零阻断交付。
- 用户文件不能作为破坏性测试样本；失败、取消、空间不足测试只使用专用临时数据。
