#!/usr/bin/env bash
# 安装器统一迁移；真实旧 updater、三种 Shell 的入口和真实 yq。
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
export REAL_GIT SOURCE_REPO="$WORK_DIR/source" SOURCE_ARCHIVE="$WORK_DIR/source.tar.gz"
REAL_GIT=$(command -v git)
mkdir -p "$SOURCE_REPO" "$WORK_DIR/bin" "$WORK_DIR/user"
cp -R "$REPO_DIR/scripts" "$SOURCE_REPO/"
cp "$REPO_DIR/"{install.sh,uninstall.sh,.env.example,.gitignore} "$SOURCE_REPO/"
init_fixture_repo "$SOURCE_REPO"
"$REAL_GIT" -C "$SOURCE_REPO" archive --prefix=source/ HEAD | gzip >"$SOURCE_ARCHIVE"
cat >"$WORK_DIR/bin/git" <<'SH'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
    case $arg in *github.com/nelvko/clashctl.git) arg=$SOURCE_REPO ;; esac
    args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    case $1 in -o) destination=$2; shift ;; esac
    shift
done
cp "$SOURCE_ARCHIVE" "$destination"
SH
chmod +x "$WORK_DIR/bin/"*

# 旧更新器确实部署新代码；新入口不加载业务库，并覆盖当前 Shell 的旧别名。
for method in git archive; do
    home="$WORK_DIR/old-$method"
    mkdir "$home"
    "$REAL_GIT" -C "$REPO_DIR" archive cb609e8 | tar -xf - -C "$home"
    if [ "$method" = git ]; then
        init_fixture_repo "$home"
    else
        ( . "$home/install.sh"; _source_manifest "$home" ) >"$home/.clashctl-files"
    fi
    printf '%s\n%s\n' "$home" "$method" >"$home/.clashctl-install"
    chmod 0600 "$home/.clashctl-install"
    printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\nCLASHCTL_UPDATE_BRANCH=master\nGH_PROXY=\n' >"$home/.env"
    PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$home" bash -c '
        . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
        clashctl update || exit 1
        clashstart && exit 92
        exit 0
    ' >"$WORK_DIR/old-update.out" 2>&1 || { cat "$WORK_DIR/old-update.out"; fail "old $method update failed"; }
    grep -q '安装迁移' "$WORK_DIR/old-update.out" || fail 'old update omitted migration instructions'
    assert_absent "$home/.clashctl-format" 'script update claimed a completed migration'
    printf 'touch "$CLASHCTL_HOME/business-loaded"\n' >"$home/scripts/lib/zz-probe.sh"
    for shell in bash zsh fish; do
        case $shell in
        bash) command=(bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashsub list') ;;
        zsh) command=(zsh -f -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashstart') ;;
        fish) command=(fish --no-config -c 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; clashctl start') ;;
        esac
        if CLASHCTL_HOME="$home" "${command[@]}" >"$WORK_DIR/gate.out" 2>&1; then fail "$shell bypassed migration"; fi
        grep -Fq -- "--home \"$home\"" "$WORK_DIR/gate.out" || fail "$shell omitted the original home"
        assert_absent "$home/business-loaded" "$shell loaded business code before migration"
    done
done

# 元数据转换保持名称唯一、当前选择及订阅路径，重复运行不再改文件。
export CLASHCTL_HOME="$WORK_DIR/metadata" CLASHCTL_SRC="$SOURCE_REPO" HOME="$WORK_DIR/user"
mkdir -p "$CLASHCTL_HOME/data/profiles"
. "$REPO_DIR/install.sh"
. "$REPO_DIR/scripts/lib/common.sh"
cat >"$CLASH_PROFILES_META" <<'YAML'
use: 2
profiles:
  - id: 1
    name: example.invalid
    url: https://example.invalid/a
    path: /preserved/a.yaml
  - id: 2
    url: https://example.invalid/b
    path: /preserved/b.yaml
YAML
_install_migrate_profiles || fail 'numeric index migration failed'
assert_eq example.invalid-2 "$("$BIN_YQ" '.use' "$CLASH_PROFILES_META")" 'current subscription'
assert_eq /preserved/b.yaml "$("$BIN_YQ" '.profiles[1].path' "$CLASH_PROFILES_META")" 'subscription path'
assert_eq false "$("$BIN_YQ" '.profiles[0] | has("id")' "$CLASH_PROFILES_META")" 'removed legacy id'
cp -p "$CLASH_PROFILES_META" "$WORK_DIR/profiles.expected"
_install_migrate_profiles || fail 'repeated metadata migration failed'
cmp "$WORK_DIR/profiles.expected" "$CLASH_PROFILES_META" || fail 'repeated migration changed metadata'

printf 'export CLASHCTL_HOME=%q\n. $CLASHCTL_HOME/scripts/cmd/clashctl.sh\n# keep\n' "$CLASHCTL_HOME" >"$HOME/.bashrc"
printf '# no trailing newline' >"$HOME/.zshrc"
_install_migrate_shell_rc || fail 'legacy shell integration migration failed'
grep -Fq '# >>> clashctl >>>' "$HOME/.bashrc" || fail 'legacy shell integration was not converted'
grep -Fq '# keep' "$HOME/.bashrc" || fail 'shell migration removed user content'
assert_eq '# no trailing newline' "$(cat "$HOME/.zshrc")" 'unrelated shell configuration'
assert_eq 21 "$(wc -c <"$HOME/.zshrc" | tr -d ' ')" 'unrelated shell bytes'
cp "$HOME/.bashrc" "$WORK_DIR/bashrc.expected"
_install_migrate_shell_rc || fail 'repeated shell migration failed'
cmp "$WORK_DIR/bashrc.expected" "$HOME/.bashrc" || fail 'repeated shell migration changed configuration'

# 旧默认目录中的嵌套布局应引导使用原目录，而不是要求卸载重装。
home="$HOME/clashctl"
mkdir "$home"
cp -a "$SOURCE_REPO/." "$home/"
printf '%s\ngit\n' "$home" >"$home/.clashctl-install"
chmod 0600 "$home/.clashctl-install"
printf 'CLASHCTL_KERNEL=mihomo\n' >"$home/.env"
mkdir -p "$home/bin/mihomo"
if env -u CLASHCTL_HOME bash "$REPO_DIR/install.sh" >"$WORK_DIR/default.out" 2>&1; then fail 'default-home check unexpectedly installed'; fi
grep -Fq -- "--home $home" "$WORK_DIR/default.out" || { cat "$WORK_DIR/default.out"; fail 'nested default home was misclassified'; }
if grep -q '卸载' "$WORK_DIR/default.out"; then fail 'supported default home requested uninstall'; fi
printf 'install-migration: ok\n'
