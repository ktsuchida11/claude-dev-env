#!/usr/bin/env bash
# global-claude-setup.sh — グローバル Claude Code セキュリティ設定セットアップ
#
# ~/.claude/settings.json にセキュリティ系の deny ルールを設定する。
# 既存の設定（voiceEnabled, language 等）はそのまま保持される。
#
# 使い方:
#   bash global-claude-setup.sh          # 設定を適用
#   bash global-claude-setup.sh --check  # 現在の設定を確認（変更なし）
#   bash global-claude-setup.sh --diff   # 適用予定の差分を表示
#
# 必要: jq

set -euo pipefail

SETTINGS_FILE="$HOME/.claude/settings.json"
MODE="${1:-apply}"

# --- 前提チェック ---
if ! command -v jq &>/dev/null; then
  echo "[ERROR] jq が必要です。brew install jq でインストールしてください"
  exit 1
fi

# --- グローバル deny ルール定義 ---
# プロジェクト共通のセキュリティルール（プロジェクト固有でないもの）
DENY_RULES='[
  "Bash(rm -rf /)",
  "Bash(rm -rf /*)",
  "Bash(rm -rf ~)",
  "Bash(rm -rf ~/*)",
  "Bash(find * -delete)",
  "Bash(find * -exec rm *)",
  "Bash(find * -exec shred *)",
  "Bash(* xargs rm *)",
  "Bash(* xargs shred *)",
  "Bash(* | xargs rm *)",
  "Bash(* | xargs shred *)",
  "Bash(* sed -i * settings.json*)",
  "Bash(* sed -i * .claude.json*)",
  "Bash(* sed -i * .mcp.json*)",
  "Bash(curl *)",
  "Bash(wget *)",
  "Bash(ssh *)",
  "Bash(scp *)",
  "Bash(nc *)",
  "Bash(ncat *)",
  "Bash(telnet *)",
  "Bash(ftp *)",
  "Bash(sudo *)",
  "Bash(chmod 777 *)",
  "Bash(eval *)",
  "Bash(exec *)",
  "Bash(nohup *)",
  "Bash(crontab *)",
  "Bash(python -c *import*socket*)",
  "Bash(python3 -c *import*socket*)",
  "Read(.env)",
  "Read(.env.*)",
  "Read(~/.ssh/**)",
  "Read(~/.aws/**)",
  "Read(~/.gnupg/**)",
  "Read(/etc/shadow)",
  "Read(/etc/gshadow)",
  "Read(./secrets/**)",
  "WebFetch"
]'

# --- 設定ファイルの存在確認・初期化 ---
ensure_settings_file() {
  if [ ! -d "$HOME/.claude" ]; then
    mkdir -p "$HOME/.claude"
    echo "[INFO] ~/.claude ディレクトリを作成しました"
  fi

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
    echo "[INFO] ~/.claude/settings.json を作成しました"
  fi

  # JSON として有効か確認
  if ! jq empty "$SETTINGS_FILE" 2>/dev/null; then
    echo "[ERROR] ${SETTINGS_FILE} が有効な JSON ではありません"
    echo "        手動で修正してから再実行してください"
    exit 1
  fi
}

# --- 期待される設定を生成 ---
build_expected() {
  local current
  current=$(cat "$SETTINGS_FILE")

  echo "$current" | jq \
    --argjson deny "$DENY_RULES" \
    '
      .permissions.deny = $deny |
      .permissions.disableBypassPermissionsMode = "disable"
    '
}

# --- check モード ---
do_check() {
  echo "=========================================="
  echo " Claude Code グローバル設定チェック"
  echo " ファイル: ${SETTINGS_FILE}"
  echo "=========================================="
  echo ""

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "[WARN] 設定ファイルが存在しません"
    echo "       bash $0 で作成・設定できます"
    return
  fi

  # deny ルール数チェック
  local current_count expected_count
  current_count=$(jq '.permissions.deny // [] | length' "$SETTINGS_FILE" 2>/dev/null || echo "0")
  expected_count=$(echo "$DENY_RULES" | jq 'length')

  if [ "$current_count" -eq "$expected_count" ]; then
    echo "[OK]   deny ルール: ${current_count} 件（期待値: ${expected_count}）"
  else
    echo "[WARN] deny ルール: ${current_count} 件（期待値: ${expected_count}）"
  fi

  # 不足ルールの表示
  local missing
  missing=$(jq -n \
    --argjson expected "$DENY_RULES" \
    --argjson current "$(jq '.permissions.deny // []' "$SETTINGS_FILE" 2>/dev/null || echo '[]')" \
    '$expected - $current | .[]' 2>/dev/null || true)

  if [ -n "$missing" ]; then
    echo ""
    echo "[WARN] 不足しているルール:"
    echo "$missing" | while read -r rule; do
      echo "       - ${rule}"
    done
  fi

  # disableBypassPermissionsMode チェック
  local bypass
  bypass=$(jq -r '.permissions.disableBypassPermissionsMode // "未設定"' "$SETTINGS_FILE" 2>/dev/null)
  if [ "$bypass" = "disable" ]; then
    echo "[OK]   disableBypassPermissionsMode: disable"
  else
    echo "[WARN] disableBypassPermissionsMode: ${bypass}（期待値: disable）"
  fi

  echo ""
}

# --- diff モード ---
do_diff() {
  ensure_settings_file

  local expected
  expected=$(build_expected)

  echo "=========================================="
  echo " 適用予定の差分"
  echo "=========================================="
  echo ""

  local tmp_current="${TMPDIR:-/tmp}/claude-setup-current-$$"
  local tmp_expected="${TMPDIR:-/tmp}/claude-setup-expected-$$"
  jq --sort-keys . "$SETTINGS_FILE" > "$tmp_current"
  echo "$expected" | jq --sort-keys . > "$tmp_expected"

  if diff "$tmp_current" "$tmp_expected" >/dev/null 2>&1; then
    echo "[OK] 変更なし — 既に最新の設定です"
  else
    diff --color=auto "$tmp_current" "$tmp_expected" || true
  fi
  rm -f "$tmp_current" "$tmp_expected"
  echo ""
}

# --- apply モード ---
do_apply() {
  ensure_settings_file

  echo "=========================================="
  echo " Claude Code グローバルセキュリティ設定"
  echo " ファイル: ${SETTINGS_FILE}"
  echo "=========================================="
  echo ""

  # バックアップ
  local backup="${SETTINGS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS_FILE" "$backup"
  echo "[INFO] バックアップ: ${backup}"

  # 期待される設定を生成して書き込み
  local expected
  expected=$(build_expected)

  # 差分チェック
  local tmp_current="${TMPDIR:-/tmp}/claude-setup-current-$$"
  local tmp_expected_apply="${TMPDIR:-/tmp}/claude-setup-expected-$$"
  jq --sort-keys . "$SETTINGS_FILE" > "$tmp_current"
  echo "$expected" | jq --sort-keys . > "$tmp_expected_apply"

  if diff "$tmp_current" "$tmp_expected_apply" >/dev/null 2>&1; then
    echo "[OK]   既に最新の設定です — 変更なし"
    rm -f "$backup" "$tmp_current" "$tmp_expected_apply"
  else
    rm -f "$tmp_current" "$tmp_expected_apply"
    echo "$expected" | jq . > "$SETTINGS_FILE"
    echo "[UPDATED] settings.json を更新しました"

    # 適用結果の概要
    local count
    count=$(jq '.permissions.deny | length' "$SETTINGS_FILE")
    echo ""
    echo "--- 適用結果 ---"
    echo "  deny ルール:                    ${count} 件"
    echo "  disableBypassPermissionsMode:   disable"
    echo "  その他の既存設定:               保持"
  fi

  echo ""
  echo "=========================================="
  echo "完了"
}

# --- メイン ---
case "$MODE" in
  --check)
    do_check
    ;;
  --diff)
    do_diff
    ;;
  apply|--apply)
    do_apply
    ;;
  *)
    echo "使い方:"
    echo "  bash $0           # 設定を適用"
    echo "  bash $0 --check   # 現在の設定を確認"
    echo "  bash $0 --diff    # 適用予定の差分を表示"
    exit 1
    ;;
esac
