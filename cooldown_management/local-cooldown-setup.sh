#!/usr/bin/env bash
# local-cooldown-setup.sh — ローカルPC用サプライチェーン・クールダウン設定
#
# DevContainerをビルド・利用するホストPC自体にもクールダウン設定を適用する。
# コンテナ内の設定（workspace/.npmrc, uv.toml, .pip.conf）とは別に、
# ホストのグローバル設定に反映する。
#
# 使い方:
#   bash local-cooldown-setup.sh          # 対話モード（確認あり）
#   bash local-cooldown-setup.sh --yes    # 自動適用（確認なし）
#   bash local-cooldown-setup.sh --check  # 現在の設定を確認するだけ
#   bash local-cooldown-setup.sh --days 3 # クールダウン期間を変更（デフォルト: 7日）
#
# 対象:
#   - npm:  ~/.npmrc に min-release-age, save-exact, ignore-scripts を追加
#   - uv:   ~/.config/uv/uv.toml に exclude-newer を追加
#   - pip:  ~/.config/pip/pip.conf に uploaded-prior-to を追加
#
# 注意:
#   - 既存の設定ファイルはバックアップ（.bak）を作成してからマージ
#   - pip の uploaded-prior-to は絶対日付のため定期的な更新が必要
#     → pip-cooldown-update.sh で自動更新可能

set -euo pipefail

# --- 引数パース ---
AUTO_YES=""
CHECK_ONLY=""
COOLDOWN_DAYS=7

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) AUTO_YES="true" ;;
    --check|-c) CHECK_ONLY="true" ;;
    --days|-d) shift; COOLDOWN_DAYS="$1" ;;
    --help|-h)
      echo "Usage: bash local-cooldown-setup.sh [--yes] [--check] [--days N]"
      echo ""
      echo "Options:"
      echo "  --yes, -y     確認なしで自動適用"
      echo "  --check, -c   現在の設定を確認するだけ（変更なし）"
      echo "  --days, -d N  クールダウン期間（デフォルト: 7日）"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# --- OS 検出 ---
OS_TYPE=""
case "$(uname -s)" in
  Darwin) OS_TYPE="macos" ;;
  Linux)  OS_TYPE="linux" ;;
  *)      echo "[ERROR] Unsupported OS: $(uname -s)"; exit 1 ;;
esac

# --- 日付計算 ---
get_cooldown_date() {
  if [ "$OS_TYPE" = "macos" ]; then
    date -u -v-${COOLDOWN_DAYS}d +%Y-%m-%d
  else
    date -u -d "$COOLDOWN_DAYS days ago" +%Y-%m-%d
  fi
}

COOLDOWN_DATE=$(get_cooldown_date)

# uv 用: RFC 3339 形式の日時文字列
get_cooldown_datetime() {
  echo "${COOLDOWN_DATE}T00:00:00Z"
}
COOLDOWN_DATETIME=$(get_cooldown_datetime)

# --- 色付き出力 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- 確認プロンプト ---
confirm() {
  if [ -n "$AUTO_YES" ]; then
    return 0
  fi
  local msg="$1"
  echo -en "${YELLOW}[確認]${NC} ${msg} (y/N): "
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- バックアップ ---
backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$file" "$backup"
    info "バックアップ作成: $backup"
  fi
}

# --- 設定にキーが含まれているか確認 ---
has_config() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] && grep -q "^${key}" "$file" 2>/dev/null
}

# --- バージョン比較 (semver) ---
# $1 >= $2 なら 0 を返す
version_gte() {
  local v1="$1" v2="$2"
  # バージョン文字列から数値部分のみ抽出（v プレフィックス除去、pre-release 除去）
  v1=$(echo "$v1" | sed 's/^v//' | sed 's/[-+].*//')
  v2=$(echo "$v2" | sed 's/^v//' | sed 's/[-+].*//')

  # printf でゼロ埋めして比較
  local IFS='.'
  read -r a1 b1 c1 <<< "$v1"
  read -r a2 b2 c2 <<< "$v2"
  a1=${a1:-0}; b1=${b1:-0}; c1=${c1:-0}
  a2=${a2:-0}; b2=${b2:-0}; c2=${c2:-0}

  if [ "$a1" -gt "$a2" ] 2>/dev/null; then return 0; fi
  if [ "$a1" -lt "$a2" ] 2>/dev/null; then return 1; fi
  if [ "$b1" -gt "$b2" ] 2>/dev/null; then return 0; fi
  if [ "$b1" -lt "$b2" ] 2>/dev/null; then return 1; fi
  if [ "$c1" -ge "$c2" ] 2>/dev/null; then return 0; fi
  return 1
}

# --- クールダウン対応の最小バージョン ---
NPM_MIN_VERSION="11.10.0"    # min-release-age サポート
PIP_MIN_VERSION="26.0"       # uploaded-prior-to サポート
UV_MIN_VERSION="0.6.0"       # exclude-newer サポート（ISO 8601 duration）

# --- バージョンチェック ---
VERSION_WARNINGS=""

check_npm_version() {
  if ! command -v npm &>/dev/null; then
    warn "npm が見つかりません"
    info "  インストール: https://nodejs.org/ または nvm を使用"
    VERSION_WARNINGS="true"
    return 1
  fi

  local current
  current=$(npm --version 2>/dev/null || echo "0.0.0")

  if version_gte "$current" "$NPM_MIN_VERSION"; then
    ok "npm v${current} (>= ${NPM_MIN_VERSION} ✓ min-release-age 対応)"
    return 0
  else
    error "npm v${current} — min-release-age には v${NPM_MIN_VERSION}+ が必要です"
    echo ""
    info "  アップグレード方法:"
    echo "    npm install -g npm@latest"
    echo "    # または Node.js ごと更新:"
    echo "    nvm install --lts       # nvm を使用している場合"
    echo "    brew upgrade node       # Homebrew を使用している場合 (macOS)"
    echo ""
    VERSION_WARNINGS="true"
    return 1
  fi
}

check_uv_version() {
  if ! command -v uv &>/dev/null; then
    warn "uv が見つかりません（インストールを推奨）"
    info "  インストール:"
    echo "    curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "    # または:"
    echo "    pip install uv"
    echo "    brew install uv         # Homebrew (macOS)"
    echo ""
    VERSION_WARNINGS="true"
    return 1
  fi

  local current
  current=$(uv self version 2>/dev/null | sed 's/^uv //' || uv --version 2>/dev/null | sed 's/^uv //' || echo "0.0.0")

  if version_gte "$current" "$UV_MIN_VERSION"; then
    ok "uv v${current} (>= ${UV_MIN_VERSION} ✓ exclude-newer 対応)"
    return 0
  else
    error "uv v${current} — exclude-newer には v${UV_MIN_VERSION}+ が必要です"
    echo ""
    info "  アップグレード方法:"
    echo "    uv self update"
    echo "    # または:"
    echo "    pip install --upgrade uv"
    echo "    brew upgrade uv         # Homebrew (macOS)"
    echo ""
    VERSION_WARNINGS="true"
    return 1
  fi
}

check_pip_version() {
  local pip_cmd="pip3"
  if ! command -v pip3 &>/dev/null; then
    pip_cmd="pip"
  fi
  if ! command -v "$pip_cmd" &>/dev/null; then
    warn "pip が見つかりません"
    VERSION_WARNINGS="true"
    return 1
  fi

  local current
  current=$($pip_cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "0.0")

  if version_gte "$current" "$PIP_MIN_VERSION"; then
    ok "pip v${current} (>= ${PIP_MIN_VERSION} ✓ uploaded-prior-to 対応)"
    return 0
  else
    error "pip v${current} — uploaded-prior-to には v${PIP_MIN_VERSION}+ が必要です"
    echo ""
    info "  アップグレード方法:"
    echo "    ${pip_cmd} install --upgrade pip"
    echo "    # または:"
    echo "    python3 -m pip install --upgrade pip"
    echo ""
    info "  pip v26.0 未満の場合は uv の使用を推奨します（相対日付対応）"
    echo ""
    VERSION_WARNINGS="true"
    return 1
  fi
}

# =============================================
echo ""
echo "=========================================="
echo " Supply Chain Cooldown - ローカルPC設定"
echo "=========================================="
echo " クールダウン期間: ${COOLDOWN_DAYS}日"
echo " OS: ${OS_TYPE}"
echo " 日付: ${COOLDOWN_DATE}"
echo "=========================================="
echo ""

# =============================================
# 0. バージョンチェック
# =============================================
echo "--- バージョンチェック ---"
echo ""

NPM_OK=""; UV_OK=""; PIP_OK=""
check_npm_version && NPM_OK="true"
check_uv_version && UV_OK="true"
check_pip_version && PIP_OK="true"

echo ""

if [ -n "$VERSION_WARNINGS" ]; then
  warn "一部のツールがクールダウン対応バージョンを満たしていません"
  info "上記のアップグレード手順を確認してください"
  echo ""
  if [ -n "$CHECK_ONLY" ]; then
    echo "--- 設定チェックを続行します ---"
    echo ""
  else
    if ! confirm "バージョンが古いツールがありますが、設定を続行しますか？"; then
      info "バージョンアップ後に再実行してください"
      exit 0
    fi
    echo ""
  fi
fi

# =============================================
# 1. npm — ~/.npmrc
# =============================================
NPMRC="$HOME/.npmrc"
echo "--- npm 設定 (${NPMRC}) ---"

if [ -z "$NPM_OK" ]; then
  warn "npm がクールダウン非対応のため設定をスキップします"
else
  if has_config "$NPMRC" "min-release-age"; then
    current=$(grep "^min-release-age" "$NPMRC" | head -1)
    ok "min-release-age 設定済み: $current"
  else
    warn "min-release-age が未設定です"
  fi

  if has_config "$NPMRC" "ignore-scripts"; then
    ok "ignore-scripts 設定済み"
  else
    warn "ignore-scripts が未設定です"
  fi

  if has_config "$NPMRC" "save-exact"; then
    ok "save-exact 設定済み"
  else
    warn "save-exact が未設定です"
  fi
fi

if [ -z "$CHECK_ONLY" ] && [ -n "$NPM_OK" ]; then
  NPMRC_NEEDS_UPDATE=""
  for key in "min-release-age" "ignore-scripts" "save-exact"; do
    if ! has_config "$NPMRC" "$key"; then
      NPMRC_NEEDS_UPDATE="true"
    fi
  done

  if [ -n "$NPMRC_NEEDS_UPDATE" ]; then
    echo ""
    info "以下の設定を ${NPMRC} に追加します:"
    ! has_config "$NPMRC" "min-release-age" && echo "  min-release-age=${COOLDOWN_DAYS}"
    ! has_config "$NPMRC" "ignore-scripts" && echo "  ignore-scripts=true"
    ! has_config "$NPMRC" "save-exact" && echo "  save-exact=true"
    echo ""

    if confirm "${NPMRC} を更新しますか？"; then
      backup_file "$NPMRC"
      # 既存ファイルがない場合は作成
      [ ! -f "$NPMRC" ] && touch "$NPMRC"

      # ヘッダーコメント（未設定の場合のみ）
      if ! grep -q "Supply Chain" "$NPMRC" 2>/dev/null; then
        echo "" >> "$NPMRC"
        echo "# Supply Chain Security (added by local-cooldown-setup.sh)" >> "$NPMRC"
      fi

      ! has_config "$NPMRC" "ignore-scripts" && echo "ignore-scripts=true" >> "$NPMRC"
      ! has_config "$NPMRC" "save-exact" && echo "save-exact=true" >> "$NPMRC"
      ! has_config "$NPMRC" "min-release-age" && echo "min-release-age=${COOLDOWN_DAYS}" >> "$NPMRC"

      ok "npm 設定を更新しました"
    fi
  else
    ok "npm — すべての設定が適用済みです"
  fi
fi
echo ""

# =============================================
# 2. uv — ~/.config/uv/uv.toml
# =============================================
UV_TOML="$HOME/.config/uv/uv.toml"
echo "--- uv 設定 (${UV_TOML}) ---"

if [ -z "$UV_OK" ]; then
  warn "uv がクールダウン非対応のためスキップします"
elif has_config "$UV_TOML" "exclude-newer"; then
  current=$(grep "^exclude-newer" "$UV_TOML" | head -1)
  ok "exclude-newer 設定済み: $current"
else
  warn "exclude-newer が未設定です"
fi

if [ -z "$CHECK_ONLY" ] && [ -n "$UV_OK" ]; then
  if ! has_config "$UV_TOML" "exclude-newer"; then
    # uv の exclude-newer は RFC 3339 絶対日時のみ対応 → cooldown-update.sh で定期更新
    echo ""
    info "以下の設定を ${UV_TOML} に追加します:"
    echo "  exclude-newer = \"${COOLDOWN_DATETIME}\""
    echo ""

    if confirm "${UV_TOML} を作成/更新しますか？"; then
      backup_file "$UV_TOML"
      mkdir -p "$(dirname "$UV_TOML")"

      if [ ! -f "$UV_TOML" ]; then
        cat > "$UV_TOML" << EOF
# Supply Chain Security: uv global configuration
# added by local-cooldown-setup.sh

# クールダウン: 絶対日時（cooldown-update.sh で定期更新）
exclude-newer = "${COOLDOWN_DATETIME}"

[pip]
# レジストリを公式 PyPI のみに固定
index-url = "https://pypi.org/simple/"
extra-index-url = []
EOF
      else
        echo "" >> "$UV_TOML"
        echo "# Supply Chain Security (added by local-cooldown-setup.sh)" >> "$UV_TOML"
        echo "exclude-newer = \"${COOLDOWN_DATETIME}\"" >> "$UV_TOML"
      fi

      ok "uv 設定を更新しました"
    fi
  else
    ok "uv — すべての設定が適用済みです"
  fi
fi
echo ""

# =============================================
# 3. pip — ~/.config/pip/pip.conf (Linux) or ~/Library/Application Support/pip/pip.conf (macOS)
# =============================================
if [ "$OS_TYPE" = "macos" ]; then
  PIP_CONF="$HOME/Library/Application Support/pip/pip.conf"
else
  PIP_CONF="$HOME/.config/pip/pip.conf"
fi
echo "--- pip 設定 (${PIP_CONF}) ---"

if [ -z "$PIP_OK" ]; then
  warn "pip がクールダウン非対応のためスキップします"
elif has_config "$PIP_CONF" "uploaded-prior-to"; then
  current=$(grep "^uploaded-prior-to" "$PIP_CONF" | head -1)
  ok "uploaded-prior-to 設定済み: $current"

  # 日付の鮮度チェック
  pip_date=$(echo "$current" | sed 's/.*=\s*//' | tr -d ' ')
  if [ "$OS_TYPE" = "macos" ]; then
    pip_epoch=$(date -jf "%Y-%m-%d" "$pip_date" +%s 2>/dev/null || echo "0")
  else
    pip_epoch=$(date -d "$pip_date" +%s 2>/dev/null || echo "0")
  fi
  today_epoch=$(date +%s)
  if [ "$pip_epoch" != "0" ]; then
    age_days=$(( (today_epoch - pip_epoch) / 86400 ))
    if [ "$age_days" -gt 14 ]; then
      warn "uploaded-prior-to が ${age_days} 日前です。更新を推奨します"
      warn "推奨値: uploaded-prior-to = ${COOLDOWN_DATE}"
    fi
  fi
else
  warn "uploaded-prior-to が未設定です"
fi

if [ -z "$CHECK_ONLY" ] && [ -n "$PIP_OK" ]; then
  NEEDS_PIP_UPDATE=""
  if ! has_config "$PIP_CONF" "uploaded-prior-to"; then
    NEEDS_PIP_UPDATE="true"
  fi

  if [ -n "$NEEDS_PIP_UPDATE" ]; then
    echo ""
    info "以下の設定を ${PIP_CONF} に追加します:"
    echo "  uploaded-prior-to = ${COOLDOWN_DATE}"
    echo ""

    if confirm "${PIP_CONF} を作成/更新しますか？"; then
      backup_file "$PIP_CONF"
      mkdir -p "$(dirname "$PIP_CONF")"

      if [ ! -f "$PIP_CONF" ]; then
        cat > "$PIP_CONF" << EOF
# Supply Chain Security: pip global configuration
# added by local-cooldown-setup.sh

[global]
# レジストリを公式 PyPI のみに固定
index-url = https://pypi.org/simple/
no-extra-index-url = true

# クールダウン: 指定日時より前にアップロードされたバージョンのみ（pip v26.0+）
# この値は定期的に更新が必要（cooldown-update.sh を使用）
uploaded-prior-to = ${COOLDOWN_DATE}
EOF
      else
        if grep -q "\[global\]" "$PIP_CONF" 2>/dev/null; then
          # [global] セクションの末尾に追加
          sed -i.tmp "/\[global\]/a\\
uploaded-prior-to = ${COOLDOWN_DATE}" "$PIP_CONF"
          rm -f "${PIP_CONF}.tmp"
        else
          echo "" >> "$PIP_CONF"
          echo "[global]" >> "$PIP_CONF"
          echo "uploaded-prior-to = ${COOLDOWN_DATE}" >> "$PIP_CONF"
        fi
      fi

      ok "pip 設定を更新しました"
    fi
  else
    ok "pip — すべての設定が適用済みです"
  fi
fi
echo ""

# =============================================
# サマリー
# =============================================
echo "=========================================="
echo " 設定確認コマンド"
echo "=========================================="
echo ""
echo "  # npm の設定確認"
echo "  npm config list"
echo ""
echo "  # uv の設定確認"
echo "  uv self version && cat ${UV_TOML}"
echo ""
echo "  # pip の設定確認"
echo "  pip config list"
echo ""
echo "=========================================="
echo ""

if [ -z "$CHECK_ONLY" ]; then
  info "pip/uv は絶対日付のため定期的な更新が必要です"
  info "以下のコマンドで pip.conf と uv.toml を一括更新できます:"
  echo ""
  echo "  bash $(dirname "$0")/cooldown-update.sh"
  echo ""
  info "cron で自動化する場合:"
  echo ""
  echo "  # 毎日9時に更新（${COOLDOWN_DAYS}日前の日付に設定）"
  echo "  0 9 * * * bash $(cd "$(dirname "$0")" && pwd)/cooldown-update.sh"
  echo ""
fi
