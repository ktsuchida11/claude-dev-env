#!/usr/bin/env bash
# session-guard.sh — SessionStart Hook（起動時の環境検証）
#
# セッション開始時に本環境の防御層の状態を検証し、結果を
# hookSpecificOutput.additionalContext でモデルのコンテキストに注入する。
# これは単なる情報表示ではなく auto モード分類器への入力になる:
# 分類器はトランスクリプトから環境制約を読むため、起動時に宣言しておくと
# 誤 allow / 誤 deny が減る。
#
# 検証項目:
#   1. settings.json の defaultMode（auto 想定）
#   2. sandbox が設定上有効か
#   3. firewall（iptables allowed-domains チェーン）が有効か（コンテナ内のみ）
#   4. hooks が /opt/claude-source と同期済みか（コンテナ内のみ）
#
# fail-open: 検証自体の失敗でセッションを止めない（常に exit 0）

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/workspace}"
SETTINGS="$PROJECT_DIR/.claude/settings.json"

CONTEXT="[session-guard] 環境状態:"
WARNINGS=""

# --- 1. permission mode ---
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  MODE=$(jq -r '.permissions.defaultMode // "unset"' "$SETTINGS" 2>/dev/null || echo "unknown")
  CONTEXT="$CONTEXT defaultMode=$MODE."
  if [ "$MODE" != "auto" ]; then
    WARNINGS="$WARNINGS defaultMode が auto 以外 ($MODE) です。"
  fi

  # --- 2. sandbox ---
  SANDBOX=$(jq -r '.sandbox.enabled // false' "$SETTINGS" 2>/dev/null || echo "unknown")
  CONTEXT="$CONTEXT sandbox.enabled=$SANDBOX."
  if [ "$SANDBOX" != "true" ]; then
    WARNINGS="$WARNINGS sandbox が無効です。"
  fi
fi

# --- 3. firewall（コンテナ内のみ。sudoers が iptables を NOPASSWD 許可している） ---
if [ -x /usr/sbin/iptables ] && [ -f /.dockerenv ]; then
  if sudo -n /usr/sbin/iptables -S OUTPUT 2>/dev/null | grep -q 'match-set allowed-domains'; then
    CONTEXT="$CONTEXT firewall=active."
  else
    CONTEXT="$CONTEXT firewall=INACTIVE."
    WARNINGS="$WARNINGS firewall (iptables allowed-domains) が有効になっていません。外部通信が制限されていない可能性があります。sudo /usr/local/bin/init-firewall.sh で再初期化できます。"
  fi
fi

# --- 4. hooks 同期（コンテナ内のみ） ---
if [ -d /opt/claude-source/hooks ] && [ -d "$PROJECT_DIR/.claude/hooks" ]; then
  DIFF_COUNT=0
  for src in /opt/claude-source/hooks/*; do
    base=$(basename "$src")
    dst="$PROJECT_DIR/.claude/hooks/$base"
    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
      DIFF_COUNT=$((DIFF_COUNT + 1))
    fi
  done
  if [ "$DIFF_COUNT" -gt 0 ]; then
    WARNINGS="$WARNINGS hooks が /opt/claude-source と ${DIFF_COUNT} 件不一致です（コンテナ再起動で同期されます）。"
  else
    CONTEXT="$CONTEXT hooks=synced."
  fi
fi

# --- 環境制約の宣言（auto モード分類器への入力） ---
CONTEXT="$CONTEXT この環境はDevContainer内で動作し、書き込みは /workspace とパッケージキャッシュと /tmp のみ、外向き通信は iptables 許可リストで制限。ファイル削除は手段を問わずユーザー確認必須のポリシー。"

if [ -n "$WARNINGS" ]; then
  CONTEXT="$CONTEXT [警告]$WARNINGS"
fi

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null
fi

exit 0
