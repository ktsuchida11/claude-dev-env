#!/usr/bin/env bash
# sync-hooks.sh — workspace/.claude/ のフック・テストをルート .claude/ に同期
#
# 用途:
#   workspace/.claude/ は DevContainer 内での Claude Code 設定（正）
#   .claude/ はホスト Mac で Claude Code を直接使う場合の設定
#   hooks とテストは共通なので、workspace 版を正として同期する
#
# 使い方:
#   bash scripts/sync-hooks.sh          # 差異チェック（デフォルト）
#   bash scripts/sync-hooks.sh --apply  # 同期実行
#
# 注意:
#   settings.json はパスが異なるため同期対象外（ホスト用とコンテナ用で別管理）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_HOOKS="$PROJECT_ROOT/workspace/.claude/hooks"
DST_HOOKS="$PROJECT_ROOT/.claude/hooks"
SRC_TESTS="$PROJECT_ROOT/workspace/.claude/tests"
DST_TESTS="$PROJECT_ROOT/.claude/tests"

MODE="${1:---check}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

has_diff=0

sync_dir() {
  local src="$1"
  local dst="$2"
  local label="$3"

  if [ ! -d "$src" ]; then
    echo -e "${RED}[ERROR]${NC} ソースが見つかりません: $src"
    return 1
  fi

  # ディレクトリが存在しない場合は作成
  if [ ! -d "$dst" ]; then
    if [ "$MODE" = "--apply" ]; then
      mkdir -p "$dst"
      echo -e "${GREEN}[CREATE]${NC} $dst"
    else
      echo -e "${YELLOW}[NEW]${NC} $dst を作成する必要があります"
      has_diff=1
    fi
  fi

  # 各ファイルを比較・同期
  for src_file in "$src"/*; do
    [ ! -f "$src_file" ] && continue
    local filename
    filename=$(basename "$src_file")
    local dst_file="$dst/$filename"

    if [ ! -f "$dst_file" ]; then
      has_diff=1
      if [ "$MODE" = "--apply" ]; then
        cp "$src_file" "$dst_file"
        echo -e "${GREEN}[COPY]${NC} $label/$filename (新規)"
      else
        echo -e "${YELLOW}[NEW]${NC}  $label/$filename — ルート側に存在しません"
      fi
    elif ! diff -q "$src_file" "$dst_file" > /dev/null 2>&1; then
      has_diff=1
      if [ "$MODE" = "--apply" ]; then
        cp "$src_file" "$dst_file"
        echo -e "${GREEN}[UPDATE]${NC} $label/$filename"
      else
        echo -e "${YELLOW}[DIFF]${NC} $label/$filename — 差異があります"
        diff --color=auto "$src_file" "$dst_file" || true
        echo ""
      fi
    else
      if [ "$MODE" != "--apply" ]; then
        echo -e "${GREEN}[OK]${NC}   $label/$filename"
      fi
    fi
  done
}

echo "=== Claude Code Hooks 同期ツール ==="
echo "ソース: workspace/.claude/ (DevContainer 用 = 正)"
echo "宛先:   .claude/ (ホスト Mac 用)"
echo ""

if [ "$MODE" = "--apply" ]; then
  echo "モード: 同期実行"
else
  echo "モード: 差異チェック (--apply で同期実行)"
fi
echo ""

sync_dir "$SRC_HOOKS" "$DST_HOOKS" "hooks"
echo ""
sync_dir "$SRC_TESTS" "$DST_TESTS" "tests"

echo ""
if [ "$has_diff" -eq 0 ]; then
  echo -e "${GREEN}すべて同期済みです${NC}"
elif [ "$MODE" = "--apply" ]; then
  echo -e "${GREEN}同期が完了しました${NC}"
else
  echo -e "${YELLOW}差異があります。bash scripts/sync-hooks.sh --apply で同期してください${NC}"
  exit 1
fi
