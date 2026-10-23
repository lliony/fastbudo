---
title: 本机固定身份签名
status: active
last_updated: 2026-10-22
---

# 本机固定身份签名

导航见[文档索引](../README.md)，构建见[项目说明](../../README.md)。此流程用于自己的 Mac，不替代公开分发的 Developer ID 和公证。

私钥由登录钥匙串保管，不导出到仓库。已有有效 Apple Development 身份可直接复用，不必额外创建自签名证书。用 `security find-identity -v -p codesigning` 查看可用身份，将选定证书的 40 位 SHA-1 保存到 `~/Library/Application Support/FastBudo/signing-identity`，之后始终复用它。配置只含证书指纹，不含私钥。

每次构建完成后执行：

```bash
bash scripts/sign-local.sh .build/xcode/Build/Products/Release/FastBudo.app
```

脚本按内置引擎、Finder 扩展、主应用的顺序签名并验证。身份不存在或失效时直接失败，不退回 `codesign --sign -`。签名完成后退出旧进程，再安装到固定的 `/Applications/FastBudo.app`。不要对正在运行的应用重新签名。

首次从 ad-hoc 切换身份可能需要重新添加辅助功能授权。以后保持证书、Bundle ID 和安装路径一致，有助于系统将不同构建识别为同一应用；最终权限是否保留仍由 macOS 决定。证书过期前需维护签名身份，不应反复新建证书。

当前 GitHub 发布包仍使用 ad-hoc 签名。直接使用应用内更新或覆盖公开安装包会替换本机签名；自用期间应在安装下载版本前使用此脚本重新签名。该脚本不自动修改更新器，也不上传证书或私钥。

依据：[Apple TN2206：Code Signing](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) 中的 Designated Requirement 与 Self-signed Identities 说明。

本机验证：修改临时副本的构建号后，使用同一证书重新签名，前后 Designated Requirement 一致；新版通过旧版身份要求及嵌套签名完整性校验。该验证证明签名身份稳定，不等同于实际跨版本辅助功能授权保留测试。
