#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

mkdir -m 0700 -- "$WORK_DIR/bin" "$WORK_DIR/home"

cat >"$WORK_DIR/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$SS_ARGS_FILE"
printf '%s' "${SS_OUTPUT:-}"
exit "${SS_RC:-0}"
EOF

cat >"$WORK_DIR/bin/netstat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NETSTAT_ARGS_FILE"
printf '%s' "${NETSTAT_OUTPUT:-}"
exit "${NETSTAT_RC:-0}"
EOF
chmod 0700 "$WORK_DIR/bin/ss" "$WORK_DIR/bin/netstat"

export PATH="$WORK_DIR/bin:/usr/bin:/bin"
export SS_ARGS_FILE="$WORK_DIR/ss.args" NETSTAT_ARGS_FILE="$WORK_DIR/netstat.args"
export CLASHCTL_HOME="$WORK_DIR/home" CLASHCTL_KERNEL=mihomo

# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

probe_port() {
    local port=$1 rc=0
    _is_port_used "$port" || rc=$?
    printf '%s' "$rc"
}

export SS_RC=0 SS_OUTPUT=$'tcp LISTEN 0 128 127.0.0.1:7890 0.0.0.0:*\n'
assert_eq 0 "$(probe_port 7890)" 'ss exact local listener is detected'
assert_eq '-H -lntu sport = :7890' "$(<"$SS_ARGS_FILE")" \
    'ss is restricted to the exact local source port'

export SS_OUTPUT=$'tcp LISTEN 0 128 127.0.0.1:78900 203.0.113.1:7890 users:(("x",pid=7890,fd=7))\n'
assert_eq 1 "$(probe_port 7890)" \
    'ss similar local port, remote port, and PID do not cause a match'

: >"$SS_ARGS_FILE"
for invalid_port in '' 0 65536 not-a-port; do
    assert_eq 1 "$(probe_port "$invalid_port")" "invalid port is rejected: [$invalid_port]"
done
assert_eq '' "$(<"$SS_ARGS_FILE")" 'invalid ports are rejected before invoking ss'

export SS_RC=64 SS_OUTPUT=
export NETSTAT_RC=0
export NETSTAT_OUTPUT=$'Active Internet connections (only servers)\nProto Recv-Q Send-Q Local Address Foreign Address State\ntcp 0 0 0.0.0.0:7890 0.0.0.0:* LISTEN\n'
assert_eq 0 "$(probe_port 7890)" 'netstat exact local listener is detected after ss failure'
assert_eq -lntu "$(<"$NETSTAT_ARGS_FILE")" 'netstat fallback only requests listeners'

export NETSTAT_OUTPUT=$'tcp 0 0 0.0.0.0:17890 203.0.113.1:7890 LISTEN 7890/x\n'
assert_eq 1 "$(probe_port 7890)" \
    'netstat similar local port, remote port, and process field do not cause a match'

printf 'port-detection: ok\n'
