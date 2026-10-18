<h1 align="center">
  clashctl
</h1>

<p align="center">
  Linux 上的 Mihomo 安装与管理工具<br />
  <sub>（原 <code>clash-for-linux-install</code>）</sub>
</p>

<p align="center">
  <a href="https://www.star-history.com/nelvko/clashctl">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/badge?repo=nelvko/clashctl&type=rank&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/badge?repo=nelvko/clashctl&type=rank" />
      <img alt="Star History Rank" src="https://api.star-history.com/badge?repo=nelvko/clashctl&type=rank" />
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://github.com/nelvko/clashctl/actions/workflows/shell-tests.yml"><img alt="Shell tests" src="https://github.com/nelvko/clashctl/actions/workflows/shell-tests.yml/badge.svg" /></a>
  <img alt="Platform: Linux" src="https://img.shields.io/badge/platform-Linux-blue?logo=linux&amp;logoColor=white" />
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/nelvko/clashctl" /></a>
  <img alt="Language: Shell" src="https://img.shields.io/github/languages/top/nelvko/clashctl" />
  <a href="https://github.com/nelvko/clashctl/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/nelvko/clashctl" /></a>
  <a href="https://deepwiki.com/nelvko/clashctl"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a>
</p>

<table>
  <tr>
    <td width="180" align="center" valign="middle">
      <a href="https://get.sushi3.cloud/#/home?code=aHno9F9G">
        <img width="80" alt="寿司云" src="https://github.com/user-attachments/assets/ef609476-caf8-49bf-981d-651b2875a3a0" />
      </a>
    </td>
    <td valign="middle">
      <b><a href="https://get.sushi3.cloud/#/home?code=aHno9F9G">寿司云</a></b> 是 AI 用途优先的 VPN，着重优化 GPT、Claude、Gemini 等海外 AI 的使用体验，提供家宽节点和中国三网优化线路。<a href="https://get.sushi3.cloud/#/home?code=aHno9F9G">注册免费体验 1 天</a>。
    </td>
  </tr>
  <tr>
    <td width="180" align="center" valign="middle">
      <a href="https://api.muteki.site/register?aff=nelvko&promo=nelvko">
        <img width="180" alt="MaruCode" src="https://github.com/user-attachments/assets/48680ff3-ffbb-492b-82ec-5e85e9502e62" />
      </a>
    </td>
    <td valign="middle">
      <b><a href="https://api.muteki.site/register?aff=nelvko&promo=nelvko">MaruCode</a></b> 是一家偶尔做做慈善的小破站 API，自营号池，主要提供 Codex、Claude Code、GPT Image 等主流模型，支持 WebSocket 协议，明码标价（Codex 0.25x, CC 1.5x），透明汇率（1:1）<a href="https://images-2.muteki.site">生图工作台🖼️</a>
    </td>
  </tr>
</table>

<p align="center">
  <img src="https://github.com/user-attachments/assets/471f3acb-faca-4610-a02e-5294e003301e" alt="preview" width="800" />
</p>

## ✨ 特性

- **开箱即用**：一键部署 `mihomo` 内核、Web 面板及运行依赖。
- **广泛兼容**：支持 `root` 与普通用户，适配主流 Linux 发行版及容器环境。兼容 systemd、OpenRC 等服务方式，提供 Bash、Zsh 和 Fish 命令集成。
- **功能丰富**：涵盖代理开关、内核启停、状态查看、日志追踪等常用操作，支持 Web 面板、TUN 模式、内核升级及 `Mixin` 配置。
- **订阅管理**：支持多订阅添加、切换与更新，集成 [subconverter](https://github.com/asdlokj1qpi233/subconverter) 实现订阅格式转换。

## 📦 安装

首次安装或更新受支持的安装，执行以下命令（已加速）：

```bash
GH_PROXY=https://gh-proxy.org/
curl -fsSL "${GH_PROXY}https://raw.githubusercontent.com/nelvko/clashctl/HEAD/install.sh" | \
  bash -s -- --gh-proxy "$GH_PROXY"
```

- `GH_PROXY`：[GitHub 下载加速代理](https://gh-proxy.org/)，失效时可更换[其他可用地址](https://ghproxy.link/)。
- 没有订阅？[click me](https://get.sushi3.cloud/#/home?code=aHno9F9G)

### 升级兼容性

- **旧安装格式**：不再迁移早期安装、搬迁旧默认目录 `~/clashctl`，或接管旧 nohup/systemd 进程。安装器会自动检查；提示“旧版安装”时，请先备份订阅和自定义配置，使用原安装的卸载脚本卸载，或通过 `--home` 另选目录。嵌套内核布局 `bin/mihomo/mihomo` 也需要先卸载后重装。
- **仅支持 mihomo**：`--kernel clash` 会报错。受支持格式的安装若仍保存 `clash`，重新运行安装器会先停止并注销旧服务，再切换到 mihomo。`clashctl update` 只更新脚本，不承担内核转换；若旧更新器已替换脚本，仍可用 `clashctl stop` 或安装目录中的卸载脚本安全清理旧内核。
- **旧维护逻辑**：不再自动暂停旧 cron 任务或等待旧进程；遗留任务和不属于当前安装的进程请用原版本工具清理。
- **订阅数据**：不再自动转换旧数字 ID 形式的订阅索引。仍使用该格式时，请先在支持它的旧版中运行订阅命令完成转换，再更新。
- **下载与续装**：`curl` 是必需依赖，不再回退到 `wget`。安装中断后可按输出提示准备完整归档，再运行保留目录中的重试命令；同目录续装会复用已保留的源码。

## 🚀 快速上手

添加并启用订阅（可选）：

```bash
clashctl sub add --use "<订阅链接>"
```

开启当前终端代理：

```bash
# 自动启动内核，并开启当前终端代理
clashctl on

# 测试连通性
curl -I https://www.google.com
```

## ⌨️ 命令一览

```text
Usage:
  clashctl COMMAND [OPTIONS]

Commands:
  on                    启用当前终端代理，自动启动内核
  off                   关闭当前终端代理，默认保留内核运行
  start                 仅启动内核
  stop                  仅停止内核
  status                内核、终端代理状态及代理地址
  ui                    面板地址
  sub                   订阅管理
  node                  节点切换
  tun                   Tun 模式
  mixin                 Mixin 配置
  secret                Web 密钥
  log                   查看日志
  upgrade               升级内核
  update                更新 clashctl
  version               脚本和内核版本

Global Options:
  -h, --help            显示帮助信息
  -v, --version         显示版本信息
```

使用示例与进阶配置，详见 [Wiki](https://github.com/nelvko/clashctl/wiki)。

## 🔄 更新

```bash
# 更新 clashctl 脚本，保留用户配置和已安装内核
clashctl update

# 升级代理内核
clashctl upgrade
```

## 🗑️ 卸载

```bash
# 清理当前 Shell 的代理环境变量（卸载脚本无法清理）
clashctl off

# 执行卸载脚本
bash "$CLASHCTL_HOME/uninstall.sh"
```

卸载会删除安装目录及其数据，需要保留的内容请提前备份。`.clashctl-backups/` 中的恢复资料会保留，确认无需回退后可手动清理。

## 📖 文档

- [Wiki](https://github.com/nelvko/clashctl/wiki)
- [常见问题](https://github.com/nelvko/clashctl/wiki/FAQ)

## ⭐ Star History

<a href="https://www.star-history.com/?repos=nelvko%2Fclashctl&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=nelvko/clashctl&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=nelvko/clashctl&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=nelvko/clashctl&type=date&legend=top-left" />
 </picture>
</a>

## ⚠️ 特别声明

- 编写本项目主要是为了学习和研究 `Shell` 编程，不得将项目内容用于违反适用法律法规及相关规定的活动。
- 本项目保留对本声明进行补充或修改的权利。使用本项目前，请阅读并遵守本声明。
