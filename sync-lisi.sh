#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
target_dir=/home/lisi/clashctl-test-src

[ "$EUID" -eq 0 ] || { printf '请以 root 执行\n' >&2; exit 1; }
[ "$source_dir" != "$target_dir" ] || { printf '请从原始工作区执行\n' >&2; exit 1; }

rm -rf -- "$target_dir"
cp -a -- "$source_dir" "$target_dir"
chown -R lisi:lisi "$target_dir"
printf '已同步到：%s\n' "$target_dir"
