#!/usr/bin/env bash
# lint-on-save.sh — PostToolUse Hook for Edit tool
# ファイル編集後に対応する linter を自動実行する。
# Exit 0 = success (情報のみ), Exit 1 = lint error (警告表示)

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

EXTENSION="${FILE_PATH##*.}"

case "$EXTENSION" in
  py)
    if command -v ruff &>/dev/null; then
      ruff check --fix --quiet "$FILE_PATH" 2>/dev/null || true
      ruff format --quiet "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  ts|tsx|js|jsx)
    if [ -f "$(dirname "$FILE_PATH")/node_modules/.bin/eslint" ]; then
      npx eslint --fix --quiet "$FILE_PATH" 2>/dev/null || true
    fi
    if command -v prettier &>/dev/null; then
      prettier --write --log-level silent "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  java)
    # Java: no auto-fix, just notify
    ;;
esac

exit 0
