---
title: 官网部署（Cloudflare Pages）
status: active
last_updated: 2026-11-11
---

# 官网部署

FastBudo 官网是仓库 `site/` 目录下的纯静态站点，托管在 **Cloudflare Pages**。

- 生产域名：<https://fastbudo.pages.dev/>（项目另绑定了 `forbettter.site`）
- Cloudflare Pages 项目名：`fastbudo`（账户 id `faefabf77939884faeaf6955dba4cc90`）
- 部署工具：`wrangler`（Cloudflare 官方 CLI），本运行手册基于 **wrangler 4.158.0** 验证
- 登录凭证：wrangler 的 OAuth 登录态保存在 `~/.wrangler/config/default.toml`，含 `pages:write` 权限与 `offline_access` 刷新令牌（令牌会自动刷新，无需每次重新登录）

> Cloudflare Pages 这个项目是 **wrangler 直接上传**部署的，**没有连接 git 仓库自动部署**。因此「改完 `site/` 并 git 推送」不会让线上生效，必须手动执行 `wrangler pages deploy`（本运行手册第 3 步）。

## 什么时候需要部署

一般「发布官网更新」= 首页版本/下载链接切换到新发布版本。改的是 `site/index.html` 里对 gitee 发布资产的引用：

- 版本文案：`当前版本 vX.Y.Z`、`下载 · vX.Y.Z`
- 下载直链 / noscript 直链 / 校验和 / 源代码 / 版本说明：`https://gitee.com/llliony/fastbudo/releases/.../vX.Y.Z/...`

确认 gitee 对应版本资产已就绪后再部署，否则首页会给出 404 的下载链接。

## 部署步骤

### 0. 预备：确认 wrangler 可用

```bash
command -v wrangler && wrangler --version   # 有则跳过本节
```

本机未全局安装时，装到临时目录（不污染全局）：

```bash
mkdir -p /tmp/npmcache && cd /tmp
npm install --cache /tmp/npmcache --no-audit --no-fund wrangler@4.158.0
# 之后用 /tmp/node_modules/.bin/wrangler 调用
```

> 若 npm 报 `EPERM ... .npm/_cacache ... root-owned files`：不要 `sudo chown` 系统缓存，
> 改用上面的 `--cache /tmp/npmcache` 全新缓存即可。

### 1. 准备待部署的 site 内容

直接部署仓库里的 `site/` 目录即可；如你在受限环境（只能写临时目录），先拷贝一份到可写位置：

```bash
cp -R <仓库>/site /tmp/fb-site
```

### 2. 放置 wrangler 登录配置（仅在默认路径不可写时）

正常情况下 wrangler 直接读 `~/.wrangler/config/default.toml` 并自动刷新令牌。
但如果在沙箱/受限环境（工作区外路径不可写，报 `EPERM` 或“Failed to write to log file”），把配置迁到临时 HOME 再运行：

```bash
WROOT=/tmp/wrhome
mkdir -p "$WROOT/.wrangler/config" "$WROOT/.wrangler/logs"
cp ~/.wrangler/config/default.toml "$WROOT/.wrangler/config/default.toml"
chmod 600 "$WROOT/.wrangler/config/default.toml"
# 之后所有 wrangler 命令加前缀： HOME="$WROOT"
```

这样令牌刷新只写临时目录，**不改动 `~/.wrangler` 原配置**。

### 3. 执行部署

```bash
cd <site 所在可写目录>          # 或 /tmp
HOME="$WROOT" wrangler pages deploy /tmp/fb-site \
  --project-name=fastbudo --branch=main
```

- `--branch=main`：项目的生产分支是 `main`，因此会发布到生产别名 `fastbudo.pages.dev`。
- 成功输出形如 `Deployment complete! ... https://<hash>.fastbudo.pages.dev`。
- 只上传改动过的文件（其余命中缓存）。

### 4. 上线验证

```bash
curl -s https://fastbudo.pages.dev/ -o /tmp/live.html
grep -o '当前版本 [0-9.a-z]*' /tmp/live.html      # 应显示最新版本
grep -o '下载 · [0-9.a-z]*' /tmp/live.html
grep -c "v0.0.12" /tmp/live.html                  # 下载链接出现次数
grep -c "v0.0.11.beta" /tmp/live.html || true      # 旧版本不应残留
```

确认版本文案、下载链接已切换，且无旧版本残留。

### 5. 清理临时产物

部署产生的临时文件含 OAuth 令牌副本，务必清理：

```bash
rm -rf /tmp/wrhome /tmp/fb-site /tmp/node_modules /tmp/npmcache /tmp/package*.json /tmp/live.html
```

## 发布历史

| 日期 | 内容 | 部署 URL |
|---|---|---|
| 2026-11-11 | 官网升级到 v0.0.12（下载链接切换 v0.0.12 资产） | `455ad1d1.fastbudo.pages.dev` |
| 2026-11-08 | 创建 Pages 项目并部署 v0.0.11.beta 首页 | `9c69df30.fastbudo.pages.dev` |

## 排障

- **令牌失效 / 需要重新登录**：删除或刷新 `~/.wrangler/config/default.toml` 后运行 `wrangler login`，在浏览器完成 OAuth 授权（wrangler 会写回 `default.toml`）。
- **`EPERM` / 目录不可写**：见第 2 步的临时 HOME 方案，或把部署目录放到可写路径。
- **部署后线上还是旧版**：确认命令带 `--branch=main`（否则可能发成预览），并用第 4 步重新抓取验证。