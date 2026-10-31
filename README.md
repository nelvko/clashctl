# clashctl-daemon

Linux 代理管理工具，提供命令行和 TUI 两种操作方式。默认通过用户级 systemd 服务运行 Mihomo 内核，支持登录自启和异常自动重启。

## 安装

在普通用户的登录会话中执行，无需 `sudo`。需要可用的用户级 systemd（243 或更新版本）。

```bash
GH_PROXY=https://gh-proxy.org/
curl -fsSL "${GH_PROXY}https://raw.githubusercontent.com/HolyDDL/clashctl-daemon/HEAD/install.sh" | \
  bash -s -- --gh-proxy "$GH_PROXY"
```

默认安装到 `~/.clashctl`。安装完成后，按提示在当前终端加载命令（Bash / Zsh）：

```bash
export CLASHCTL_HOME="$HOME/.clashctl"
source "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
```

Fish 使用安装提示中的 `.fish` 加载命令。也可以重新打开终端。

如果已克隆本仓库，在源码目录执行 `bash install.sh --local` 即可安装。需要自定义位置时使用：

```bash
bash install.sh --local --install-dir /data/clashctl
```

自定义目录需要当前用户有写入权限，并与源码目录分开。

## TUI 使用

打开终端管理界面：

```bash
clashctl tui
```

在 **Language / 语言** 中选择 **English** 或 **简体中文**，选择后立即生效并自动保存。使用方向键选择、Enter 进入，`q` 或 Esc 返回，也可以按数字直接选择。

首页快捷键：`o` 启用代理、`f` 关闭终端代理、`x` 停止内核、`n` 选择节点、`s` 切换订阅、`a` 添加订阅。节点和订阅选择支持 `/` 搜索，当前选项以 `●` 标记。菜单会记住选择位置，小终端自动滚动。

常用操作：

- **Subscriptions**：添加、切换和更新订阅，选择当前订阅的策略组与节点。
- **Terminal proxy**：启用或关闭当前终端代理，也可同时停止内核。
- **Kernel & startup**：启动、停止、重启内核，以及设置登录自启。
- **Proxy ports / Proxy settings**：修改代理端口和运行模式。

代理开关在退出 TUI 后同步到当前终端；不操作开关则保留原来的代理设置。关闭终端代理默认保留后台内核运行。

## 命令行使用

首次使用时添加并启用自己的订阅：

```bash
clashctl sub add --use "<订阅链接>"
clashctl on                      # 启动内核，并为当前终端启用代理
clashctl status                  # 查看状态和代理地址
```

日常启停：

```bash
clashctl off                     # 关闭当前终端代理，保留内核运行
clashctl off --stop              # 关闭当前终端代理并停止内核
clashctl start                   # 仅启动内核，不修改终端代理变量
clashctl stop                    # 仅停止内核，不清除终端代理变量
```

切换订阅、调整配置或排查问题：

```bash
clashctl sub use                 # 交互选择订阅
clashctl sub update --all        # 更新全部订阅
clashctl mixin -e                # 编辑配置，校验后重启生效
clashctl log -n 50               # 查看最近 50 行日志
```

默认代理端口为 `37700`。启动时优先复用已保存的端口，发生占用冲突时自动选择空闲高位端口并保存。浏览器等客户端使用 `clashctl status` 显示的地址；端口变化后，在各终端重新执行 `clashctl on`。

## 卸载

```bash
clashctl uninstall
```

卸载会停止服务、取消自启，删除安装目录及其中的订阅和配置，并清除当前终端的代理变量和命令；需要保留的数据请提前备份。
