#!/usr/bin/env bash
# shellcheck disable=SC2016  # 引导文件中的变量必须原样写入
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'command rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 description=$3
    [ "$expected" = "$actual" ] ||
        fail "$description: expected [$expected], got [$actual]"
}

CLASHCTL_HOME="$WORK_DIR/install home"
CLASHCTL_SRC=$REPO_DIR
CLASHCTL_KERNEL=mihomo
export CLASHCTL_HOME CLASHCTL_SRC CLASHCTL_KERNEL
# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"

CLASHCTL_CMD_DIR="$CLASHCTL_HOME/scripts/cmd"
mkdir -p -- "$CLASHCTL_CMD_DIR"
printf '%s\n' 'CLASHCTL_TEST_LOADED=1' >"$CLASHCTL_CMD_DIR/clashctl.sh"
printf '%s\n' '# fish completion fixture' >"$CLASHCTL_CMD_DIR/clashctl.fish"
export CLASHCTL_CMD_DIR CLASHCTL_COLOR=never

# 保存真实 detect_rc（随后用参数化桩覆盖；文件尾部恢复以验证 fish 判定）
_real_detect_rc=$(declare -f detect_rc)

RC_MODE=none
detect_rc() {
    SHELL_RC_BASH=
    SHELL_RC_ZSH=
    SHELL_RC_FISH=
    case $RC_MODE in
    bash) SHELL_RC_BASH="$WORK_DIR/user/.bashrc" ;;
    fish) SHELL_RC_FISH="$WORK_DIR/user/fish/conf.d/clashctl.fish" ;;
    esac
    export SHELL_RC_BASH SHELL_RC_ZSH SHELL_RC_FISH
}

rc=0
apply_rc >"$WORK_DIR/manual.stdout" 2>"$WORK_DIR/manual.stderr" || rc=$?
assert_eq 2 "$rc" 'missing shell startup files use the manual-load status'
assert_eq 0 "${CLASHCTL_TEST_LOADED:-0}" 'shell integration does not load commands'

RC_MODE=bash
mkdir -p -- "$WORK_DIR/user"
printf '%s\n' 'export USER_SETTING=keep' >"$WORK_DIR/user/.bashrc"
apply_rc >"$WORK_DIR/bash.stdout" 2>"$WORK_DIR/bash.stderr"
apply_rc >"$WORK_DIR/bash-second.stdout" 2>"$WORK_DIR/bash-second.stderr"
assert_eq 1 "$(grep -Fc '# >>> clashctl >>>' "$WORK_DIR/user/.bashrc")" \
    'bash managed block remains idempotent'
assert_eq 0 "${CLASHCTL_TEST_LOADED:-0}" 'writing shell integration does not load commands'
grep -Fqs 'export USER_SETTING=keep' "$WORK_DIR/user/.bashrc" ||
    fail 'bash integration removed an unrelated setting'
bash -n "$WORK_DIR/user/.bashrc"

cat >"$WORK_DIR/user/.bashrc" <<'EOF'
export USER_SETTING=keep
# >>> clashctl >>>
incomplete=user-content
EOF
cp -p -- "$WORK_DIR/user/.bashrc" "$WORK_DIR/user/.bashrc.expected"
rc=0
apply_rc >"$WORK_DIR/incomplete.stdout" 2>"$WORK_DIR/incomplete.stderr" || rc=$?
assert_eq 1 "$rc" 'incomplete bash managed markers fail without rewriting the file'
cmp -s -- "$WORK_DIR/user/.bashrc.expected" "$WORK_DIR/user/.bashrc" ||
    fail 'incomplete bash managed block was modified'

RC_MODE=fish
apply_rc >"$WORK_DIR/fish.stdout" 2>"$WORK_DIR/fish.stderr"
fish_sum=$(sha256sum "$SHELL_RC_FISH")
apply_rc >"$WORK_DIR/fish-second.stdout" 2>"$WORK_DIR/fish-second.stderr"
assert_eq "$fish_sum" "$(sha256sum "$SHELL_RC_FISH")" 'unchanged fish integration is not rewritten'
assert_eq 644 "$(stat -c %a -- "$SHELL_RC_FISH")" 'fish integration permissions'

printf '%s\n' '# user-owned fish configuration' 'set -gx USER_SETTING keep' >"$SHELL_RC_FISH"
cp -p -- "$SHELL_RC_FISH" "$WORK_DIR/fish.expected"
rc=0
apply_rc >"$WORK_DIR/fish-foreign.stdout" 2>"$WORK_DIR/fish-foreign.stderr" || rc=$?
assert_eq 1 "$rc" 'non-managed fish configuration is not overwritten'
cmp -s -- "$WORK_DIR/fish.expected" "$SHELL_RC_FISH" ||
    fail 'non-managed fish configuration was modified'

rc=0
(
    RC_MODE=bash
    # shellcheck disable=SC2317  # apply_rc 间接调用该失败桩
    _append_source_block() { return 1; }
    apply_rc
) >"$WORK_DIR/write-failure.stdout" 2>"$WORK_DIR/write-failure.stderr" || rc=$?
assert_eq 1 "$rc" 'real shell write failures are not downgraded to manual mode'

# ── 真实 detect_rc：fish 需「二进制存在 且 ~/.config/fish 已存在」（使用证据）──
eval "$_real_detect_rc"
detect_home="$WORK_DIR/detect-user"
fake_bin="$WORK_DIR/fakebin"
mkdir -p -- "$detect_home" "$fake_bin"
printf '#!/bin/sh\n' >"$fake_bin/fish"
chmod 0755 -- "$fake_bin/fish"
PATH="$fake_bin:$PATH" HOME="$detect_home" detect_rc || true
[ -z "${SHELL_RC_FISH:-}" ] ||
    fail 'fish without an existing config directory must not be targeted'
mkdir -p -- "$detect_home/.config/fish"
PATH="$fake_bin:$PATH" HOME="$detect_home" detect_rc || true
[ -n "${SHELL_RC_FISH:-}" ] ||
    fail 'fish with an existing config directory must be targeted'

# 卸载按路径匹配：含空格的自家引导删除，外部安装和不完整块原样保留。
owned_rc="$WORK_DIR/owned.rc"
foreign_rc="$WORK_DIR/foreign.rc"
printf 'user-setting=keep\n' >"$owned_rc"
printf 'foreign-setting=keep\n' >"$foreign_rc"
_append_source_block "$owned_rc"
CLASHCTL_HOME="$WORK_DIR/other install" _append_source_block "$foreign_rc"
cp "$foreign_rc" "$WORK_DIR/foreign.expected"
cat "$foreign_rc" >>"$owned_rc"
_remove_source_block "$owned_rc"
{ printf 'user-setting=keep\n'; cat "$WORK_DIR/foreign.expected"; } >"$WORK_DIR/owned.expected"
cmp "$owned_rc" "$WORK_DIR/owned.expected" || fail 'uninstall did not limit managed block removal to the current path'
_remove_source_block "$foreign_rc"
cmp "$foreign_rc" "$WORK_DIR/foreign.expected" || fail 'uninstall changed another installation block'
printf '# >>> clashctl >>>\nexport CLASHCTL_HOME=%q' "$CLASHCTL_HOME" >"$owned_rc"
cp "$owned_rc" "$WORK_DIR/incomplete.expected"
_remove_source_block "$owned_rc"
cmp "$owned_rc" "$WORK_DIR/incomplete.expected" || fail 'uninstall changed incomplete markers'

# 不再识别旧裸引导行；未托管的用户内容原样保留。
printf 'export CLASHCTL_HOME=%s\n. $CLASHCTL_HOME/scripts/cmd/clashctl.sh\n' "$CLASHCTL_HOME" >"$owned_rc"
cp "$owned_rc" "$WORK_DIR/unmanaged.expected"
_remove_source_block "$owned_rc"
cmp "$owned_rc" "$WORK_DIR/unmanaged.expected" || fail 'unmanaged loader was changed'

# Fish 托管头和安装路径必须同时匹配。
detect_rc() {
    SHELL_RC_BASH='' SHELL_RC_ZSH=''
    SHELL_RC_FISH="$WORK_DIR/uninstall.fish"
}
detect_rc
CLASHCTL_HOME="$WORK_DIR/other install" _write_fish_rc
cp "$SHELL_RC_FISH" "$WORK_DIR/fish.other.expected"
revoke_rc >/dev/null 2>&1
cmp "$SHELL_RC_FISH" "$WORK_DIR/fish.other.expected" || fail 'uninstall removed another installation fish file'
_write_fish_rc
revoke_rc
[ ! -e "$SHELL_RC_FISH" ] || fail 'uninstall retained its own fish file'

# 用户先移除了 Shell 二进制，仍应清理实际存在且归属匹配的引导。
eval "$_real_detect_rc"
mkdir -p "$detect_home/.config/fish/conf.d"
touch "$detect_home/.bashrc" "$detect_home/.zshrc"
_append_source_block "$detect_home/.bashrc"
_append_source_block "$detect_home/.zshrc"
SHELL_RC_FISH="$detect_home/.config/fish/conf.d/clashctl.fish"
_write_fish_rc
(
    # shellcheck disable=SC2317  # revoke_rc 间接使用 command，模拟 Shell 已移除。
    command() {
        case "$*" in
        '-v zsh' | '-v fish') return 1 ;;
        *) builtin command "$@" ;;
        esac
    }
    HOME="$detect_home" revoke_rc
) || fail 'cleanup depended on shell executables'
! grep -q clashctl "$detect_home/.bashrc" || fail 'bash loader remains'
! grep -q clashctl "$detect_home/.zshrc" || fail 'zsh loader remains without executable'
[ ! -e "$SHELL_RC_FISH" ] || fail 'fish loader remains without executable'

printf 'shell-integration: ok\n'
