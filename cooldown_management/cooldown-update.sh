#!/usr/bin/env bash
# cooldown-update.sh — pip.conf / uv.toml の絶対日付を自動更新
#
# pip (uploaded-prior-to) と uv (exclude-newer) は絶対日付のみ対応のため、
# 定期的に更新する必要がある。
# ※ npm (min-release-age) は相対日数対応のため更新不要
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
    COOLDOWN_DATETIME=$(date -u -v-${COOLDOWN_DAYS}d +%Y-%m-%dT00:00:00Z)
    PIP_CONF="$HOME/Library/Application Support/pip/pip.conf"
    ;;
  Linux)
    COOLDOWN_DATE=$(date -u -d "$COOLDOWN_DAYS days ago" +%Y-%m-%d)
    COOLDOWN_DATETIME=$(date -u -d "$COOLDOWN_DAYS days ago" +%Y-%m-%dT00:00:00Z)
    PIP_CONF="$HOME/.config/pip/pip.conf"
    ;;
  *)
    echo "[ERROR] Unsupported OS"; exit 1
    ;;
esac

UV_TOML="$HOME/.config/uv/uv.toml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# DevContainer 内かローカルかで workspace パスを切り替え
if [ -f "/.dockerenv" ] || grep -q 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
  # DevContainer 内: /workspace 直下
  DEVCONTAINER_PIP_CONF="/workspace/.pip.conf"
  DEVCONTAINER_UV_TOML="/workspace/uv.toml"
else
  # ローカル: プロジェクトルートからの相対パス
  DEVCONTAINER_PIP_CONF="${PROJECT_ROOT}/workspace/.pip.conf"
  DEVCONTAINER_UV_TOML="${PROJECT_ROOT}/workspace/uv.toml"
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
echo " uv:   ${COOLDOWN_DATETIME}"
echo " ※ npm は相対日数 (min-release-age) のため更新不要"
echo "=========================================="
echo ""

# --- 日付の妥当性チェック（--check モード対応） ---
STALENESS_THRESHOLD=14

check_staleness() {
  local conf_file="$1"
  local label="$2"
  local key="$3"
  local date_format="$4"  # "date" or "datetime"

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
  echo "--- 日付の鮮度チェック ---"
  echo ""
  check_staleness "$DEVCONTAINER_PIP_CONF" "DevContainer .pip.conf" "uploaded-prior-to" "date"
  check_staleness "$DEVCONTAINER_UV_TOML" "DevContainer uv.toml" "exclude-newer" "datetime"
  check_staleness "$PIP_CONF" "ローカル pip.conf" "uploaded-prior-to" "date"
  check_staleness "$UV_TOML" "ローカル uv.toml" "exclude-newer" "datetime"
  echo ""
  exit 0
fi

# --- pip ---
echo "--- pip (uploaded-prior-to) ---"
update_config "$PIP_CONF" "ローカル pip.conf" "uploaded-prior-to" "$COOLDOWN_DATE"
update_config "$DEVCONTAINER_PIP_CONF" "DevContainer .pip.conf" "uploaded-prior-to" "$COOLDOWN_DATE"
echo ""

# --- uv ---
echo "--- uv (exclude-newer) ---"
update_config "$UV_TOML" "ローカル uv.toml" "exclude-newer" "\"${COOLDOWN_DATETIME}\""
update_config "$DEVCONTAINER_UV_TOML" "DevContainer uv.toml" "exclude-newer" "\"${COOLDOWN_DATETIME}\""
echo ""

echo "=========================================="
echo "完了"
