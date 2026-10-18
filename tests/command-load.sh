#!/usr/bin/env bash
# 命令加载与分发冒烟测试：在隔离的假安装目录里 source 加载器，
# 确认公开子命令能加载、分发，并能在无内核时查看帮助。
# 不依赖内核、网络与服务，可在 CI 长期保留。
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap '/usr/bin/rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# 造一个最小安装目录：只需要 scripts/ 与 .env，供加载器 source。
HOME_DIR="$WORK_DIR/home"
mkdir -p "$HOME_DIR/scripts"
cp -r "$REPO_DIR/scripts/lib" "$HOME_DIR/scripts/lib"
cp -r "$REPO_DIR/scripts/cmd" "$HOME_DIR/scripts/cmd"
: >"$HOME_DIR/.env"
printf 'CLASHCTL_KERNEL=mihomo\n' >>"$HOME_DIR/.env"

export CLASHCTL_HOME="$HOME_DIR"
export CLASHCTL_SRC="$HOME_DIR"
export CLASHCTL_KERNEL=mihomo
export INIT_TYPE=nohup
# 加载库时 common.sh 会请求系统 yq；无副作用，保持安静。
# shellcheck source=/dev/null
. "$HOME_DIR/scripts/cmd/clashctl.sh"

# 1) 每个公开子命令都必须有 clashXXX 函数
for sub in on off start stop status ui sub node tun mixin secret log upgrade update version help; do
    declare -F "clash${sub}" >/dev/null 2>&1 ||
        fail "subcommand not loaded: clashctl ${sub} (clash${sub} undefined)"
done

# 2) 未定义子命令必须被拒绝，且返回非零
if clashctl definitely-not-a-command >"$WORK_DIR/unknown.out" 2>&1; then
    fail 'unknown subcommand was accepted'
fi
grep -q 'Unknown subcommand: definitely-not-a-command' "$WORK_DIR/unknown.out" ||
    fail 'unknown subcommand had no diagnosis'

# 3) help 必须能执行且列出核心命令
clashctl help >"$WORK_DIR/help.out" 2>&1 || fail 'clashctl help failed'
for word in on off start stop status ui sub node update; do
    grep -q "  $word " "$WORK_DIR/help.out" ||
        fail "help does not list: $word"
done

# 4) 声明支持 -h/--help 的子命令，其 --help 不应因缺依赖而崩溃。
#    其余命令（如 log）本就没有 help 分支，不在此断言。
#    -h 是最轻的路径，能在无内核/无配置下验证函数体前半段接线正确。
for sub in on off start stop status sub node tun mixin secret upgrade update version; do
    rc=0
    clashctl "$sub" --help >"$WORK_DIR/$sub-help.out" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] ||
        fail "clashctl $sub --help returned $rc: $(head -1 "$WORK_DIR/$sub-help.out")"
    [ -s "$WORK_DIR/$sub-help.out" ] ||
        fail "clashctl $sub --help produced no output"
done

# status 在服务未运行时返回非零属正常，只要求它执行到状态查询。
rc=0
clashctl status >"$WORK_DIR/status.out" 2>&1 || rc=$?
case "$(cat "$WORK_DIR/status.out")" in
*"Unknown subcommand"*) fail 'clashctl status was not dispatched' ;;
esac

# 5) 关键路径变量必须指向 data/（运行时布局），而不是旧的 resources/
case "$CLASH_CONFIG_BASE" in
"$CLASHCTL_HOME/data/"*) ;;
*) fail "CLASH_CONFIG_BASE not under data/: $CLASH_CONFIG_BASE" ;;
esac
case "$CLASH_CONFIG_MIXIN" in
"$CLASHCTL_HOME/data/"*) ;;
*) fail "CLASH_CONFIG_MIXIN not under data/: $CLASH_CONFIG_MIXIN" ;;
esac
[ "$BIN_KERNEL" = "$CLASHCTL_HOME/bin/mihomo" ] ||
    fail "BIN_KERNEL layout unexpected: $BIN_KERNEL"

# 6) 三种 Shell 都区分未知选项和子命令，并报告用户的原始输入。
command_in_shell() {
    local shell=$1
    shift
    local -a command
    # shellcheck disable=SC2016  # 变量在被调用的 Shell 中展开。
    case $shell in
    bash) command=(bash --noprofile --norc -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl "$@"' command-test) ;;
    zsh) command=(zsh -f -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl "$@"' command-test) ;;
    fish) command=(fish --no-config -c 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; clashctl $argv' --) ;;
    esac
    env -i PATH="$PATH" HOME="$WORK_DIR/user" CLASHCTL_HOME="$HOME_DIR" \
        TERM=dumb "${command[@]}" "$@"
}

mkdir -p "$WORK_DIR/user"
for shell in bash zsh fish; do
    command -v "$shell" >/dev/null || fail "$shell is required"
    for input in --unknown-option unknown-command; do
        case $input in
        -*) expected="Unknown option: $input" ;;
        *) expected="Unknown subcommand: $input" ;;
        esac
        if command_in_shell "$shell" "$input" >"$WORK_DIR/unknown.stdout" 2>"$WORK_DIR/unknown.stderr"; then
            fail "$shell accepted $input"
        fi
        grep -Fq "$expected" "$WORK_DIR/unknown.stderr" || fail "$shell misreported $input"
        [ ! -s "$WORK_DIR/unknown.stdout" ] || fail "$shell wrote $input error to stdout"
        if grep -Fq "clash$input" "$WORK_DIR/unknown.stderr"; then
            fail "$shell exposed an internal function name"
        fi
    done
done

# 7) 版本入口一致，不依赖内核启动、配置或网络。
for shell in bash zsh fish; do
    for flag in -v --version version; do
        output=$(command_in_shell "$shell" "$flag" 2>"$WORK_DIR/version.err") || fail "$shell $flag failed"
        [ "$output" = $'clashctl（无 Git 版本信息）\nmihomo：未安装' ] || fail "$shell $flag: $output"
        [ ! -s "$WORK_DIR/version.err" ] || fail "$shell $flag wrote an error"
    done
    if command_in_shell "$shell" -v unexpected >"$WORK_DIR/version-invalid.out" 2>&1; then
        fail "$shell accepted an unexpected version argument"
    fi
done

# 位于父仓库中的归档安装，不能误报父仓库的版本。
git -C "$WORK_DIR" init -q
printf parent >"$WORK_DIR/parent"
git -C "$WORK_DIR" add parent
git -C "$WORK_DIR" -c user.name=test -c user.email=test@example.invalid commit -qm parent
for shell in bash zsh fish; do
    output=$(command_in_shell "$shell" -v) || fail "$shell archive version failed"
    [[ $output == 'clashctl（无 Git 版本信息）'* ]] || fail "$shell reported parent repository version"
done

# 用假内核确认只传入 -v，有本地修改时仍只显示提交号。
mkdir -p "$HOME_DIR/bin"
cat >"$HOME_DIR/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = -v ] || exit 91
[ ! -e "$CLASHCTL_HOME/fail-version" ] || exit 23
cat "$CLASHCTL_HOME/version-output"
EOF
chmod +x "$HOME_DIR/bin/mihomo"
printf 'Mihomo Meta v1.19.32 linux amd64 with go1.26.8 Wed Sep 30 16:55:58 UTC 2026\nUse tags: with_gvisor\n' \
    >"$HOME_DIR/version-output"
git -C "$HOME_DIR" init -q
printf initial >"$HOME_DIR/version-fixture"
git -C "$HOME_DIR" add version-fixture
git -C "$HOME_DIR" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
revision=$(git -C "$HOME_DIR" rev-parse --short HEAD)
for state in clean dirty; do
    if [ "$state" = dirty ]; then
        printf changed >"$HOME_DIR/version-fixture"
    fi
    for shell in bash zsh fish; do
        for flag in -v --version version; do
            output=$(command_in_shell "$shell" "$flag") || fail "$shell $flag $state failed"
            [ "$output" = "clashctl $revision"$'\nmihomo v1.19.32' ] || fail "$shell $flag $state: $output"
        done
    done
done

# 不丢失 nightly 提交标识，保留 mihomo 曾使用的 Clash Meta banner。
for flavor in nightly meta; do
    case $flavor in
    nightly) kernel=mihomo; banner='Mihomo Meta alpha-abcdef linux amd64 with go1.26.8'; expected='mihomo alpha-abcdef' ;;
    meta) kernel=mihomo; banner='Clash Meta alpha-123456 linux amd64 with go1.21.4'; expected='mihomo alpha-123456' ;;
    esac
    printf 'CLASHCTL_KERNEL=%s\n' "$kernel" >"$HOME_DIR/.env"
    printf '%s\nUse tags: fixture\n' "$banner" >"$HOME_DIR/version-output"
    for shell in bash zsh fish; do
        output=$(command_in_shell "$shell" -v) || fail "$shell $flavor version failed"
        [ "$output" = "clashctl $revision"$'\n'"$expected" ] || fail "$shell $flavor: $output"
    done
done

printf 'unexpected output\n' >"$HOME_DIR/version-output"
for shell in bash zsh fish; do
    if command_in_shell "$shell" -v >"$WORK_DIR/version.stdout" 2>"$WORK_DIR/version.stderr"; then
        fail "$shell accepted an unrecognized version banner"
    fi
    grep -q '无法读取内核版本信息' "$WORK_DIR/version.stderr" || fail "$shell missing version diagnosis"
done
touch "$HOME_DIR/fail-version"
for shell in bash zsh fish; do
    rc=0
    command_in_shell "$shell" -v >"$WORK_DIR/version.stdout" 2>"$WORK_DIR/version.stderr" || rc=$?
    [ "$rc" -eq 23 ] || fail "$shell hid kernel version failure: $rc"
done

printf 'command-load: ok\n'
