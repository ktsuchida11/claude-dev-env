#!/usr/bin/env bash
# permission-denied-log.sh — PermissionDenied Hook（監査ログ）
#
# auto モード（Claude Code 2.1.177+）では拒否の発生源が
# deny ルール / hook / LLM 分類器のいずれかになり、後から追いにくい。
# 本フックは PermissionDenied イベント（分類器 deny の後にも発火）の入力を
# JSONL で追記し、「なぜ止まったか」の監査線を確保する。
#
# 方針:
#   - {"retry": true} は返さない（勝手な再試行はさせない）
#   - fail-open: ログ失敗でもセッションを止めない（常に exit 0）

# 注意: set -e は使わない（ログ失敗で hook エラーにしないため）
set -u

INPUT=$(cat 2>/dev/null) || INPUT=""

LOG_DIR="${CLAUDE_PROJECT_DIR:-/workspace}/.claude/logs"
LOG_FILE="$LOG_DIR/permission-denied.jsonl"

mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ] && echo "$INPUT" | jq empty 2>/dev/null; then
  # 入力 JSON をタイムスタンプ付きで 1 行に圧縮して追記（8KB 上限）
  echo "$INPUT" | jq -c --arg ts "$TS" '{ts:$ts} + .' 2>/dev/null | head -c 8192 >> "$LOG_FILE" 2>/dev/null
  echo "" >> "$LOG_FILE" 2>/dev/null
else
  # JSON でない/空の入力もそのまま記録（先頭 1KB）
  printf '{"ts":"%s","raw":%s}\n' "$TS" "$(printf '%s' "${INPUT:0:1024}" | jq -Rs . 2>/dev/null || echo '""')" >> "$LOG_FILE" 2>/dev/null
fi

exit 0
