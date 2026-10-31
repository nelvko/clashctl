#!/usr/bin/env bash
# 真实 Bash/Zsh 加载器与 Git/压缩包更新；只有下载来源替换成本地 fixture。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v zsh >/dev/null || fail 'zsh is required'
command -v fish >/dev/null || fail 'fish is required'
export REAL_GIT SOURCE_REPO="$WORK_DIR/source" SOURCE_ARCHIVE="$WORK_DIR/source.tar.gz"
REAL_GIT=$(command -v git)
mkdir -p "$SOURCE_REPO" "$WORK_DIR/bin"
cp -a "$REPO_DIR/scripts" "$SOURCE_REPO/"
cp "$REPO_DIR/"{install.sh,uninstall.sh,.env.example,.gitignore} "$SOURCE_REPO/"
printf 'CLASHCTL_TEST_VERSION=old\n' >"$SOURCE_REPO/scripts/cmd/version.sh"
printf '\nfunction __clashctl_test_version; echo old; end\n' >>"$SOURCE_REPO/scripts/cmd/clashctl.fish"
"$REAL_GIT" -C "$SOURCE_REPO" init -q -b master
"$REAL_GIT" -C "$SOURCE_REPO" config user.email test@example.invalid
"$REAL_GIT" -C "$SOURCE_REPO" config user.name test
"$REAL_GIT" -C "$SOURCE_REPO" add .
"$REAL_GIT" -C "$SOURCE_REPO" commit -qm initial
INITIAL_HEAD=$("$REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
. "$REPO_DIR/install.sh"
for shell in bash zsh; do
    for method in git archive; do
        home_dir="$WORK_DIR/$shell-$method"
        if [ "$method" = git ]; then
            "$REAL_GIT" clone -q "$SOURCE_REPO" "$home_dir"
        else
            mkdir "$home_dir"
            "$REAL_GIT" -C "$SOURCE_REPO" archive HEAD | tar -x -C "$home_dir"
            _source_manifest "$home_dir" >"$home_dir/.clashctl-files"
        fi
        printf '%s\n%s\n' "$home_dir" "$method" >"$home_dir/.clashctl-install"
        printf 'CLASHCTL_KERNEL=mihomo\nCLASHCTL_UPDATE_BRANCH=master\nGH_PROXY=\n' >"$home_dir/.env"
    done
done
cp -a "$WORK_DIR/bash-archive" "$WORK_DIR/fish-archive"
printf '%s\narchive\n' "$WORK_DIR/fish-archive" >"$WORK_DIR/fish-archive/.clashctl-install"
sed -i 's/function __clashctl_test_version; echo old;/function __clashctl_test_version; echo new;/' "$SOURCE_REPO/scripts/cmd/clashctl.fish"
printf 'clashfuture() { printf "new-command\\n"; }\n' >"$SOURCE_REPO/scripts/cmd/future.sh"
printf 'CLASHCTL_TEST_VERSION=new\n' >"$SOURCE_REPO/scripts/cmd/version.sh"
printf 'new_helper=true\n' >"$SOURCE_REPO/scripts/new-helper.sh"
"$REAL_GIT" -C "$SOURCE_REPO" add .
"$REAL_GIT" -C "$SOURCE_REPO" commit -qm update
"$REAL_GIT" -C "$SOURCE_REPO" archive --prefix=source/ HEAD | gzip >"$SOURCE_ARCHIVE"
cat >"$WORK_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ -n "${CHECKOUT_FAILURE:-}" ] && [ "${1:-}" = -C ]; then
    home_dir=$2
    if [ "${3:-}" = checkout ]; then
        printf 'CLASHCTL_TEST_VERSION=partial\n' >"$home_dir/scripts/cmd/version.sh"
        printf 'partial helper\n' >"$home_dir/scripts/new-helper.sh"
        case "$CHECKOUT_FAILURE" in
        detached) "$REAL_GIT" "$@" || exit 1 ;;
        signal) kill -TERM "$PPID" ;;
        esac
        exit 1
    fi
    if [ "$CHECKOUT_FAILURE" = rollback ] && [ "${3:-}" = reset ]; then exit 1; fi
fi
args=()
for arg in "$@"; do
    case "$arg" in *github.com/HolyDDL/clashctl-daemon.git) arg=$SOURCE_REPO ;; esac
    args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
STUB
cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    case "$1" in -o) destination=$2; shift ;; esac
    shift
done
cp "$SOURCE_ARCHIVE" "$destination"
STUB
chmod +x "$WORK_DIR/bin/"*
for shell in bash zsh; do
    shell_args=(-c)
    [ "$shell" != zsh ] || shell_args=(-f -c)
    for method in git archive; do
        # shellcheck disable=SC2016  # 变量由被测 Shell 展开。
        PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$WORK_DIR/$shell-$method" "$shell" "${shell_args[@]}" '
            . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
            [ "$CLASHCTL_TEST_VERSION" = old ] || exit 1
            clashctl update || exit 1
            [ "$CLASHCTL_TEST_VERSION" = new ] || exit 1
        ' >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail "$shell $method update failed"; }
    done
done
# Fish 的 update 在 Bash 子进程中执行，成功后还必须刷新当前会话的原生包装器。
# shellcheck disable=SC2016  # 变量由被测 Fish 展开。
PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$WORK_DIR/fish-archive" fish --no-config -c '
    source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; or exit 1
    test (__clashctl_test_version) = old; or exit 1
    function __clashctl_test_version; echo session; end
    clashctl update --help; or exit 1
    test (__clashctl_test_version) = session; or exit 1
    functions -q clashfuture; and exit 1

    # 空参数同样会执行更新，不能把“存在参数”误判为帮助。
    clashctl update ""; or exit 1
    test (__clashctl_test_version) = new; or exit 1
    test (clashctl future) = new-command; or exit 1
    function __clashctl_test_version; echo stale; end
    clashctl update; or exit 1
    test (__clashctl_test_version) = new; or exit 1

    # 失败应保留退出码和当前函数；源码已更新但 Fish 加载失败时单独报错。
    function __clashctl_test_version; echo retained; end
    function __clashctl_run; return 17; end
    clashctl update
    test $status -eq 17; or exit 1
    test (__clashctl_test_version) = retained; or exit 1
    function __clashctl_run; return 0; end
    printf "end\n" >"$CLASHCTL_HOME/scripts/cmd/clashctl.fish"
    clashctl update
    test $status -eq 1; or exit 1
' >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail 'Fish current-session update failed'; }
grep -q '当前 Fish 加载失败' "$WORK_DIR/output" || fail 'Fish reload failure was not diagnosed'
# checkout 可在索引、HEAD 尚未切换时失败，也可在切换后失败；两者都必须恢复。
for shell in bash zsh; do
    shell_args=(-c)
    [ "$shell" != zsh ] || shell_args=(-f -c)
    for failure in partial detached signal collision rollback; do
        home_dir="$WORK_DIR/$shell-failure-$failure"
        "$REAL_GIT" clone -q "$SOURCE_REPO" "$home_dir"
        "$REAL_GIT" -C "$home_dir" reset --hard -q "$INITIAL_HEAD"
        printf '%s\ngit\n' "$home_dir" >"$home_dir/.clashctl-install"
        printf 'CLASHCTL_KERNEL=mihomo\nCLASHCTL_UPDATE_BRANCH=master\nGH_PROXY=\n' >"$home_dir/.env"
        mkdir "$home_dir/data"
        printf 'user runtime\n' >"$home_dir/data/private"
        printf 'untracked user file\n' >"$home_dir/user-notes"
        if [ "$failure" = collision ]; then printf 'user helper\n' >"$home_dir/scripts/new-helper.sh"; fi
        PATH="$WORK_DIR/bin:$PATH" CHECKOUT_FAILURE="$failure" CLASHCTL_HOME="$home_dir" \
            "$shell" "${shell_args[@]}" '
                . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
                clashctl update
            ' >"$WORK_DIR/output" 2>&1 && fail "$shell accepted failed checkout: $failure"
        [ "$(cat "$home_dir/user-notes")" = 'untracked user file' ] || fail 'rollback lost untracked user file'
        [ "$(cat "$home_dir/data/private")" = 'user runtime' ] || fail 'rollback lost runtime data'
        grep -qx 'CLASHCTL_KERNEL=mihomo' "$home_dir/.env" || fail 'rollback modified config'
        if [ "$failure" = rollback ]; then
            grep -q '无法完整恢复原版本' "$WORK_DIR/output" || { cat "$WORK_DIR/output"; fail 'rollback failure was hidden'; }
            recovery=$(find "$WORK_DIR" -maxdepth 1 -name "$shell-failure-$failure.update.*" -print -quit)
            [ -n "$recovery" ] && [ -f "$recovery/keep" ] || fail 'rollback failure removed recovery information'
            [ "$(head -n 1 "$recovery/git-previous")" = "$INITIAL_HEAD" ] || fail 'rollback lost previous commit'
            continue
        fi
        [ "$("$REAL_GIT" -C "$home_dir" rev-parse HEAD)" = "$INITIAL_HEAD" ] || fail "$shell rollback changed HEAD: $failure"
        [ "$("$REAL_GIT" -C "$home_dir" symbolic-ref HEAD)" = refs/heads/master ] || fail "$shell rollback lost branch: $failure"
        [ -z "$("$REAL_GIT" -C "$home_dir" status --porcelain --untracked-files=no)" ] || fail "$shell rollback left tracked changes: $failure"
        if [ "$failure" = collision ]; then
            [ "$(cat "$home_dir/scripts/new-helper.sh")" = 'user helper' ] || fail 'update overwrote untracked collision'
            grep -q '更新会覆盖未跟踪文件' "$WORK_DIR/output" || fail 'untracked collision was not diagnosed'
        else
            [ ! -e "$home_dir/scripts/new-helper.sh" ] || fail "$shell rollback left partial new file: $failure"
            grep -q '已恢复原版本' "$WORK_DIR/output" || { cat "$WORK_DIR/output"; fail "$shell rollback was not reported: $failure"; }
            # 恢复后应可重试成功，不能再被“存在本地代码修改”阻塞。
            PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$home_dir" "$shell" "${shell_args[@]}" '
                . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
                clashctl update || exit 1
                [ "$CLASHCTL_TEST_VERSION" = new ]
            ' >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail "$shell could not retry after $failure"; }
        fi
        [ -z "$(find "$WORK_DIR" -maxdepth 1 -name "$shell-failure-$failure.update.*" -print -quit)" ] || fail 'recovered update left temporary files'
    done
done
printf 'update-shells: ok\n'
