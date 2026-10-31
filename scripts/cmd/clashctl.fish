if not set -q CLASHCTL_HOME
    # CLASHCTL_HOME is injected at install time (see preflight.sh apply_rc).
    # If absent, the installer did not finish — bail out quietly.
    exit 0
end

function __clashctl_run --description 'invoke a clash* bash function with argv'
    set -l fn $argv[1]
    bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && "$1" "${@:2}"' -- $fn $argv[2..-1]
end

function __clashctl_state_path
    if set -q XDG_CACHE_HOME
        echo $XDG_CACHE_HOME/clashctl/proxy.fish
    else
        echo $HOME/.cache/clashctl/proxy.fish
    end
end

function clashon --description 'enable terminal proxy, starting the kernel if needed'
    if set -q argv[1]
        __clashctl_run clashon $argv
        return $status
    end

    set -l state (__clashctl_state_path)
    mkdir -p -- (dirname -- $state)
    set -l tmp $state.tmp.$fish_pid

    bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashon "$@" 1>&2 && _dump_proxy_env_fish' -- $argv >$tmp
    set -l rc $status

    if test $rc -ne 0
        rm -f -- $tmp
        return $rc
    end

    mv -f -- $tmp $state
    source $state
end

function clashoff --description 'disable terminal proxy, optionally stopping the kernel'
    if set -q argv[1]
        if test (count $argv) -ne 1; or test "$argv[1]" != --stop
            __clashctl_run clashoff $argv
            return $status
        end
    end

    # 有效的 off 请求始终清理当前终端，即使 --stop 未能停止内核。
    rm -f -- (__clashctl_state_path)
    set -e http_proxy https_proxy HTTP_PROXY HTTPS_PROXY \
        all_proxy ALL_PROXY no_proxy NO_PROXY
    __clashctl_run clashoff $argv
end

function clashtui --description 'interactive management with terminal proxy synchronization'
    if not test -f "$CLASHCTL_HOME/scripts/cmd/tui.sh"
        echo 'TUI files are missing or the installation is out of date.' >&2
        echo 'Run clashctl update, then reopen your terminal.' >&2
        return 1
    end
    if set -q argv[1]
        __clashctl_run clashtui $argv
        return $status
    end
    set -l result (mktemp)
    or return 1
    __clashctl_run _tui_session "$result"
    set -l tui_rc $status
    set -l action (cat -- "$result")
    rm -f -- "$result"
    switch "$action"
        case on
            set -l proxy_file (mktemp)
            or return 1
            __clashctl_run _tui_proxy_env_fish >"$proxy_file"
            set -l proxy_rc $status
            if test $proxy_rc -eq 0
                source "$proxy_file"
                set proxy_rc $status
            end
            rm -f -- "$proxy_file"
            if test $proxy_rc -ne 0
                return $proxy_rc
            end
        case off
            rm -f -- (__clashctl_state_path)
            set -e http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    end
    return $tui_rc
end

function clashuninstall --description 'uninstall and clean the invoking shell'
    if set -q argv[1]
        switch $argv[1]
            case -h --help
                __clashctl_run clashuninstall $argv
                return $status
        end
    end
    set -l installation "$CLASHCTL_HOME"
    set -l commands clashctl
    for file in "$installation"/scripts/cmd/*.sh
        set -l name (basename -- "$file" .sh)
        if test "$name" != clashctl; and string match -rq '^[a-zA-Z0-9_-]+$' -- "$name"
            set -a commands clash$name
        end
    end
    env CLASHCTL_UNINSTALL_SHELL_CLEANUP=1 bash "$installation/uninstall.sh" $argv
    set -l uninstall_rc $status
    if test $uninstall_rc -ne 0
        return $uninstall_rc
    end
    if test -e "$installation"; or test -L "$installation"
        return 0
    end
    set -e http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    set -e CLASHCTL_HOME CLASHCTL_SRC CLASHCTL_KERNEL INIT_TYPE
    functions -e $commands __clashctl_run __clashctl_state_path
    printf '当前终端代理与 clashctl 命令已清理。\n'
    return 0
end

function clashupdate --description 'update clashctl and reload the current Fish session'
    __clashctl_run clashupdate $argv
    set -l rc $status
    if test $rc -ne 0
        return $rc
    end
    if set -q argv[1]; and contains -- "$argv[1]" -h --help
        return 0
    end
    source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"
    or begin
        echo 'clashctl 已更新，但当前 Fish 加载失败，请重开终端' >&2
        return 1
    end
end

function clashctl
    set -l sub help
    if set -q argv[1]
        set sub $argv[1]
        set argv $argv[2..-1]
    end
    switch $sub
        case -h --help help
            set sub help
        case -v --version
            set sub version
        case '-*'
            echo "Unknown option: $sub" >&2
            echo "Use 'clashctl help' for usage information." >&2
            return 1
    end

    set -l target clash$sub
    if not functions -q $target
        if string match -rq '^[a-zA-Z0-9_-]+$' -- "$sub"; and test -f "$CLASHCTL_HOME/scripts/cmd/$sub.sh"
            source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"
            or return 1
        end
    end
    if not functions -q $target
        echo "Unknown subcommand: $sub" >&2
        echo "Use 'clashctl help' for usage information." >&2
        return 1
    end
    $target $argv
end

# Auto-define clash<name> wrappers for every cmd/*.sh except those we own.
if test -d $CLASHCTL_HOME/scripts/cmd
    for cmd_file in $CLASHCTL_HOME/scripts/cmd/*.sh
        set -l base (basename -- $cmd_file .sh)
        switch $base
            case clashctl on off tui uninstall update
                continue
        end
        set -l fn clash$base
        if functions -q $fn
            continue
        end
        function $fn --inherit-variable fn
            __clashctl_run $fn $argv
        end
    end
end
