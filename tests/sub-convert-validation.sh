#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

CLASH_RESOURCES_DIR="$WORK_DIR/resources"
CLASH_CONFIG_DEBUG="$WORK_DIR/last-failed.yaml"
CLASH_CONFIG_DEBUG_RAW="$WORK_DIR/last-failed.raw"
BIN_SUBCONVERTER_LOG="$WORK_DIR/converter.log"
mkdir -p "$CLASH_RESOURCES_DIR"

# shellcheck source=../scripts/cmd/sub.sh
. "$REPO_DIR/scripts/cmd/sub.sh"
# shellcheck source=../scripts/lib/convert.sh
. "$REPO_DIR/scripts/lib/convert.sh"

_download_convert_config() { cp "$WORK_DIR/input" "$1"; }
_normalize_sub_config() { [ -s "$1" ]; }
_valid_config() { grep -q '^config: valid$' "$1"; }
_valid_sub_nodes() { grep -q '^nodes: present$' "$1"; }

assert_rejected() {
    rm -f "$CLASH_CONFIG_DEBUG"
    if _sub_download 'https://example.com/sub' convert >"$WORK_DIR/out" 2>&1; then
        printf 'invalid converted subscription was accepted\n' >&2
        exit 1
    fi
    [ -z "$_SUB_DL_FILE" ] || exit 1
    if [ -s "$WORK_DIR/input" ]; then
        cmp -s "$WORK_DIR/input" "$CLASH_CONFIG_DEBUG" || exit 1
    else
        [ ! -e "$CLASH_CONFIG_DEBUG" ] || exit 1
    fi
}

printf 'config: invalid\nnodes: present\n' >"$WORK_DIR/input"
assert_rejected

printf 'config: valid\nnodes: absent\n' >"$WORK_DIR/input"
assert_rejected

: >"$WORK_DIR/input"
assert_rejected

printf 'config: valid\nnodes: present\n' >"$WORK_DIR/input"
if ! _sub_download 'https://example.com/sub' convert >"$WORK_DIR/out" 2>&1; then
    cat "$WORK_DIR/out" >&2
    exit 1
fi
[ -s "$_SUB_DL_FILE" ] || exit 1
cmp -s "$WORK_DIR/input" "$_SUB_DL_FILE" || exit 1

printf 'sub-convert-validation: ok\n'
