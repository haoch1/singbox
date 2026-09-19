#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/singbox.sh"

if command -v bash >/dev/null 2>&1; then
    bash -n "$SCRIPT"
else
    # Windows checkout environments may not have Bash installed; dash can
    # still catch unmatched quotes and other lexical errors.
    command -v sh >/dev/null 2>&1
    sh -n "$SCRIPT"
fi

grep -Fq 'DEFAULT_PORT=8443' "$SCRIPT"
grep -Fq 'DEFAULT_SNI="www.bing.com"' "$SCRIPT"
grep -Fq 'xtls-rprx-vision' "$SCRIPT"
grep -Fq 'reality-keypair' "$SCRIPT"
grep -Fq '[1] 添加节点' "$SCRIPT"
grep -Fq '[5] 清空所有节点' "$SCRIPT"
grep -Fq '[11] 更新核心' "$SCRIPT"
grep -Fq '[12] 更新管理脚本' "$SCRIPT"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$SCRIPT"
fi

printf 'singbox smoke tests passed\n'
