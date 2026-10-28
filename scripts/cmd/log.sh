#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source 时补载解释器适配。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

clashlog() {
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashlog "$@"
        return
    fi
    service_log "$@"
}
