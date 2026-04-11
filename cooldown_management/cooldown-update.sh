#!/usr/bin/env bash
# cooldown-update.sh — pip.conf の絶対日付を自動更新
#
# pip (uploaded-prior-to) は絶対日付のみ対応のため、定期的に更新する必要がある。
# ※ npm (min-release-age) と uv (exclude-newer) は相対期間対応のため更新不要
# ローカルPC と DevContainer 内の両方の設定ファイルを更新する。
#
# 使い方:
#   bash cooldown-update.sh          # デフォルト7日前
#   bash cooldown-update.sh 3        # 3日前
#   bash cooldown-update.sh --check  # 日付の鮮度チェックのみ（更新しない）
#
# cron で自動化:
#   0 9 * * * bash /path/to/cooldown-update.sh 7

set -euo pipefail

COOLDOWN_DAYS="${1:-7}"

# OS 検出・日付計算
case "$(uname -s)" in
  Darwin)
    COOLDOWN_DATE=$(date -u -v-${COOLDOWN_DAYS}d +%Y-%m-%d)
    PIP_CONF="$HOME/Library/Application Support/pip/pip.conf"
    ;;
  Linux)
    COOLDOWN_DATE=$(date -u -d "$COOLDOWN_DAYS days ago" +%Y-%m-%d)
    PIP_CONF="$HOME/.config/pip/pip.conf"
    ;;
  *)
    echo "[ERROR] Unsupported OS"; exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# DevContainer 内かローカルかで workspace パスを切り替え
if [ -f "/.dockerenv" ] || grep -q 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
  # DevContainer 内: /workspace 直下
  DEVCONTAINER_PIP_CONF="/workspace/.pip.conf"
else
  # ローカル: プロジェクトルートからの相対パス
  DEVCONTAINER_PIP_CONF="${PROJECT_ROOT}/workspace/.pip.conf"
fi

# --- 汎用アップデート関数 ---
update_config() {
  local conf_file="$1"
  local label="$2"
  local key="$3"
  local new_value="$4"

  if [ ! -f "$conf_file" ]; then
    echo "[SKIP] ${label}: ファイルが存在しません"
    return
  fi

  if ! grep -q "^${key}" "$conf_file" 2>/dev/null; then
    echo "[SKIP] ${label}: ${key} が未設定です"
    return
  fi

  local current
  current=$(grep "^${key}" "$conf_file" | head -1 | sed 's/.*=\s*//' | tr -d ' "')

  if [ "$current" = "$new_value" ]; then
    echo "[OK]      ${label}: 既に最新 (${new_value})"
    return
  fi

  if [ "$(uname -s)" = "Darwin" ]; then
    sed -i '' "s|^${key}.*|${key} = ${new_value}|" "$conf_file"
  else
    sed -i "s|^${key}.*|${key} = ${new_value}|" "$conf_file"
  fi

  echo "[UPDATED] ${label}: ${current} → ${new_value}"
}

echo "=========================================="
echo " Cooldown Update (${COOLDOWN_DAYS}日前)"
echo " pip:  ${COOLDOWN_DATE}"
echo " ※ npm (min-release-age) と uv (exclude-newer) は相対期間のため更新不要"
echo "=========================================="
echo ""

# --- 日付の妥当性チェック（--check モード対応） ---
STALENESS_THRESHOLD=14

check_staleness() {
  local conf_file="$1"
  local label="$2"
  local key="$3"

  if [ ! -f "$conf_file" ]; then
    return
  fi

  local current_value
  current_value=$(grep "^${key}" "$conf_file" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d ' "')
  if [ -z "$current_value" ]; then
    return
  fi

  # 日付部分を抽出（datetime の場合は T 以前を取得）
  local date_part="${current_value%%T*}"

  local conf_epoch today_epoch age_days
  case "$(uname -s)" in
    Darwin)
      conf_epoch=$(date -jf "%Y-%m-%d" "$date_part" +%s 2>/dev/null || echo "0")
      ;;
    Linux)
      conf_epoch=$(date -d "$date_part" +%s 2>/dev/null || echo "0")
      ;;
  esac
  today_epoch=$(date +%s)

  if [ "$conf_epoch" = "0" ]; then
    echo "[WARN]    ${label}: 日付のパースに失敗 (${current_value})"
    return
  fi

  age_days=$(( (today_epoch - conf_epoch) / 86400 ))
  if [ "$age_days" -gt "$STALENESS_THRESHOLD" ]; then
    echo "[STALE]   ${label}: ${current_value} — ${age_days}日前（${STALENESS_THRESHOLD}日超過、更新を推奨）"
  else
    echo "[FRESH]   ${label}: ${current_value} — ${age_days}日前"
  fi
}

if [ "${1:-}" = "--check" ]; then
  echo "--- 日付の鮮度チェック（pip のみ） ---"
  echo ""
  check_staleness "$DEVCONTAINER_PIP_CONF" "DevContainer .pip.conf" "uploaded-prior-to"
  check_staleness "$PIP_CONF" "ローカル pip.conf" "uploaded-prior-to"
  echo ""
  exit 0
fi

# --- pip ---
echo "--- pip (uploaded-prior-to) ---"
update_config "$PIP_CONF" "ローカル pip.conf" "uploaded-prior-to" "$COOLDOWN_DATE"
update_config "$DEVCONTAINER_PIP_CONF" "DevContainer .pip.conf" "uploaded-prior-to" "$COOLDOWN_DATE"
echo ""

echo "=========================================="
echo "完了"
