#!/usr/bin/env bash

# TUI labels use English as stable message keys. Service/kernel logs keep their original text.
_tui_tr() {
    local message=$1
    if [ "${_TUI_LANGUAGE:-en}" = zh-CN ]; then
        case $message in
        'Resize terminal to at least 40 x 15.') message='请将终端调整到至少 40 列 × 15 行。' ;;
        'q: exit') message='q：退出' ;;
        'Home/End: first/last') message='Home/End：首项/末项' ;;
        'o Enable  f Disable  x Stop  n Nodes  s Subscriptions  a Add') message='o 启用  f 关闭  x 停止内核  n 节点  s 订阅  a 添加' ;;
        'Ready') message='就绪' ;;
        'Working...') message='正在处理…' ;;
        'Done. Proxy changes apply to your shell when you exit.') message='已完成。终端代理设置会在退出后同步到当前 Shell。' ;;
        'Cannot read nodes. Check the controller.') message='无法读取节点，请检查控制接口。' ;;
        'No selectable policy groups.') message='没有可手动选择的策略组。' ;;
        '/: search') message='/: 搜索' ;;
        'Search') message='搜索' ;;
        'No matches. Showing all items.') message='无匹配结果，已显示全部。' ;;
        'Start, stop, restart and login startup') message='管理内核运行与登录自启' ;;
        'Add links and manage subscription updates') message='添加链接、切换与更新订阅' ;;
        'Choose routes and compare latency') message='选择策略组节点、比较延迟' ;;
        'HTTP / SOCKS listeners and addresses') message='管理监听端口与代理地址' ;;
        'Routing mode, LAN access and TUN') message='规则模式、局域网访问与 TUN' ;;
        'Web dashboard and controller access') message='管理 Web 面板与控制接口' ;;
        'Inspect logs, status and configuration') message='查看日志、运行状态与配置' ;;
        'Control the proxy for your current shell') message='控制当前 Shell 的代理环境' ;;
        'Overview') message='总览' ;;
        'Kernel & startup') message='内核与自启' ;;
        'Subscriptions') message='订阅管理' ;;
        'Nodes & latency') message='节点与延迟' ;;
        'Proxy ports') message='代理端口' ;;
        'Proxy settings') message='代理设置' ;;
        'Dashboard & secret') message='面板与密钥' ;;
        'Logs & diagnostics') message='日志与诊断' ;;
        'Terminal proxy') message='当前终端代理' ;;
        'Action') message='执行操作' ;;
        'Start kernel') message='启动内核' ;;
        'Stop kernel') message='停止内核' ;;
        'Restart kernel') message='重启内核' ;;
        'Enable login startup') message='启用登录自启' ;;
        'Disable login startup') message='关闭登录自启' ;;
        'Detailed status') message='详细状态' ;;
        'Enable proxy (start kernel if needed)') message='启用代理（需要时启动内核）' ;;
        'Disable proxy (keep kernel running)') message='关闭代理（保留内核运行）' ;;
        'Disable proxy and stop kernel') message='关闭代理并停止内核' ;;
        'List policy groups') message='查看策略组' ;;
        'Switch node') message='选择节点' ;;
        'Switch node with latency') message='选择节点并显示延迟' ;;
        'Test group latency') message='策略组延迟测速' ;;
        'List subscriptions') message='查看订阅' ;;
        'Add & activate subscription') message='添加并启用订阅' ;;
        'Switch subscription') message='切换订阅' ;;
        'Update all subscriptions') message='更新全部订阅' ;;
        'Delete subscription') message='删除订阅' ;;
        'Subscription log') message='订阅操作日志' ;;
        'Select node for current subscription') message='选择当前订阅的节点' ;;
        'Select node with latency') message='选择节点并显示延迟' ;;
        'Subscription URL') message='订阅链接' ;;
        'Mixed HTTP + SOCKS port') message='HTTP / SOCKS 混合端口' ;;
        'Dedicated HTTP port') message='独立 HTTP 端口' ;;
        'Dedicated SOCKS port') message='独立 SOCKS 端口' ;;
        'Current proxy addresses') message='当前代理地址' ;;
        'Mixed port (1-65535)') message='混合端口（1–65535）' ;;
        'HTTP port (0 disables this listener)') message='HTTP 端口（0 关闭独立监听）' ;;
        'SOCKS port (0 disables this listener)') message='SOCKS 端口（0 关闭独立监听）' ;;
        'Mode: Rule') message='规则模式' ;;
        'Mode: Global') message='全局模式' ;;
        'Mode: Direct') message='直连模式' ;;
        'Allow LAN access') message='允许局域网访问' ;;
        'Restrict proxy to this computer') message='仅允许本机访问' ;;
        'Enable TUN (sudo required)') message='启用 TUN（需要 sudo）' ;;
        'Disable TUN') message='关闭 TUN' ;;
        'Edit full Mixin') message='编辑完整 Mixin 配置' ;;
        'Show dashboard addresses') message='查看面板地址' ;;
        'Set controller address') message='设置控制接口地址' ;;
        'Change controller secret') message='修改控制接口密钥' ;;
        'Controller address (for example 127.0.0.1:9090)') message='控制接口地址（例如 127.0.0.1:9090）' ;;
        'New controller secret') message='新的控制接口密钥' ;;
        'Recent kernel logs (100 lines)') message='最近 100 行内核日志' ;;
        'Versions') message='版本信息' ;;
        'Show runtime configuration') message='查看运行配置' ;;
        'Stop the kernel for all connected clients?') message='停止内核并断开所有客户端连接？' ;;
        'Allow remote clients? Configure authentication and network access first.') message='允许远程客户端访问？请先配置身份验证和网络访问权限。' ;;
        'Enable TUN with sudo? This changes network routing.') message='使用 sudo 启用 TUN？此操作会更改网络路由。' ;;
        '  Kernel: %s    Mode: %s    Mixed port: %s') message='  内核：%s    模式：%s    混合端口：%s' ;;
        '  Service: %s    Login startup: %s    Terminal proxy: %s') message='  服务：%s    登录自启：%s    终端代理：%s' ;;
        '  Subscription: %s') message='  当前订阅：%s' ;;
        '  HTTP: %s    SOCKS: %s') message='  HTTP：%s    SOCKS：%s' ;;
        '  Enlarge the terminal to at least %s rows.') message='  请将终端高度调整到至少 %s 行。' ;;
        '  Up/Down or j/k: move   Enter: select   q/Esc: back') message='  方向键或 j/k：移动   Enter：选择   q/Esc：返回' ;;
        '  Number keys select immediately.') message='  按数字键直接选择。' ;;
        'Press any key to return...') message='按任意键返回……' ;;
        'Operation failed (exit %d). Review the output above.') message='操作失败（退出码 %d），请查看上方输出。' ;;
        'empty cancels') message='留空取消' ;;
        'Configured %s: %s') message='当前配置 %s：%s' ;;
        'This service backend does not support automatic startup.') message='当前服务后端不支持自动启动。' ;;
        'Login startup enabled.') message='已启用登录自启。' ;;
        'Login startup disabled.') message='已关闭登录自启。' ;;
        'Starting the kernel through clashctl enables automatic startup again.') message='通过 clashctl 启动内核时，会再次启用自动启动。' ;;
        'The proxy selection will apply to this terminal when you exit the TUI.') message='退出 TUI 后，此代理设置将同步到当前终端。' ;;
        'Port must be an integer between 0 and 65535.') message='端口必须是 0 到 65535 之间的整数。' ;;
        'The mixed proxy port must be between 1 and 65535.') message='混合代理端口必须在 1 到 65535 之间。' ;;
        'Use a controller address such as 127.0.0.1:9090 or [::1]:9090.') message='请输入控制接口地址，例如 127.0.0.1:9090 或 [::1]:9090。' ;;
        'Cannot read kernel state; no settings changed.') message='无法读取内核状态，未修改设置。' ;;
        'Wait for the kernel to finish changing state.') message='内核正在启停，请稍后重试。' ;;
        'Settings saved, but the kernel could not restart. Check the logs.') message='设置已保存，但内核重启失败，请查看日志。' ;;
        'Settings saved and kernel restarted.') message='设置已保存，内核已重启。' ;;
        'Settings saved. They will apply on the next kernel start.') message='设置已保存，将在下次启动内核时生效。' ;;
        'Run clashctl on in each terminal to refresh its proxy environment.') message='请在各终端执行 clashctl on 刷新代理环境。' ;;
        'running') message='运行中' ;;
        'stopped') message='已停止' ;;
        'failed') message='异常停止' ;;
        'starting') message='启动中' ;;
        'stopping') message='停止中' ;;
        'unknown') message='未知' ;;
        'enabled') message='已启用' ;;
        'disabled') message='已关闭' ;;
        'unavailable') message='不支持' ;;
        'rule') message='规则' ;;
        'global') message='全局' ;;
        'direct') message='直连' ;;
        'Disabled') message='未配置' ;;
        'No active subscription') message='未启用订阅' ;;
        'Cannot read subscription') message='无法读取订阅' ;;
        'Language saved.') message='语言设置已保存。' ;;
        'Cannot save the language preference.') message='无法保存语言设置。' ;;
        'The TUI requires an interactive terminal (TERM must not be dumb).') message='TUI 需要交互终端（TERM 不能为 dumb）。' ;;
        esac
    fi
    printf '%s' "$message"
}

# Formats are fixed UI messages, never user input.
_tui_say() {
    local format
    format=$(_tui_tr "$1")
    shift
    printf "$format\n" "$@"
}

_tui_load_language() {
    local language=''
    _TUI_LANGUAGE=en
    if [ -f "$CLASH_DATA_DIR/tui-language" ]; then
        IFS= read -r language <"$CLASH_DATA_DIR/tui-language" || true
        case $language in en | zh-CN) _TUI_LANGUAGE=$language ;; esac
    fi
}

_tui_set_language() {
    local language=$1 candidate
    case $language in en | zh-CN) ;; *) return 1 ;; esac
    candidate=$(mktemp "$CLASH_DATA_DIR/tui-language.XXXXXX") || return 1
    if ! printf '%s\n' "$language" >"$candidate" ||
        ! command mv -fT -- "$candidate" "$CLASH_DATA_DIR/tui-language"; then
        command rm -f -- "$candidate"
        _ui_error "$(_tui_tr 'Cannot save the language preference.')"
        return 1
    fi
    _TUI_LANGUAGE=$language
}
