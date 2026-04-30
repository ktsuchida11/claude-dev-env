#!/usr/bin/env bash
# =============================================================================
# setup.sh — ホスト Mac のセキュリティ統合セットアップ
#
# Claude Code を安全に使うための Mac 側セキュリティ設定を一括で適用します。
#
# 実行内容:
#   1. Claude Code グローバル設定の強化（deny ルール適用）
#   2. パッケージマネージャのクールダウン設定（npm, pip, uv）
#   3. IOC データベースの初期化（脅威インテリジェンス）
#   4. launchd ジョブの登録（定期チェック・IOC 更新）
#   5. 初回セキュリティ監査の実行
#
# 使い方:
#   bash mac_security_check/setup.sh          # 対話モード（確認あり）
#   bash mac_security_check/setup.sh --yes    # 全自動（確認なし）
#   bash mac_security_check/setup.sh --check  # 現在の設定状態を確認のみ
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Linux で実行された場合のガード
if [ "$(uname -s)" = "Linux" ]; then
    echo "このスクリプトは macOS 専用です。"
    echo "Linux では以下を使用してください:"
    echo "  bash host_security/setup.sh"
    echo "  bash linux_security_check/setup.sh"
    exit 1
fi

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MODE="${1:---interactive}"
STEP=0
TOTAL=5

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${BOLD}${CYAN}[Step ${STEP}/${TOTAL}]${NC} $1"
  echo "─────────────────────────────────────────"
}

confirm() {
  if [ "$MODE" = "--yes" ] || [ "$MODE" = "-y" ]; then
    return 0
  fi
  echo -en "  続行しますか? [Y/n] "
  read -r answer
  case "$answer" in
    [nN]*) return 1 ;;
    *) return 0 ;;
  esac
}

# === チェックモード ===
if [ "$MODE" = "--check" ] || [ "$MODE" = "-c" ]; then
  echo -e "${BOLD}=== ホスト Mac セキュリティ設定チェック ===${NC}"
  echo ""

  # 1. Claude Code グローバル設定
  echo -e "${CYAN}[1] Claude Code グローバル設定${NC}"
  if [ -f "$SCRIPT_DIR/global-claude-setup.sh" ]; then
    bash "$SCRIPT_DIR/global-claude-setup.sh" check 2>/dev/null || true
  else
    echo -e "  ${YELLOW}global-claude-setup.sh が見つかりません${NC}"
  fi
  echo ""

  # 2. クールダウン設定
  echo -e "${CYAN}[2] クールダウン設定${NC}"
  if [ -f "$PROJECT_ROOT/cooldown_management/local-cooldown-setup.sh" ]; then
    bash "$PROJECT_ROOT/cooldown_management/local-cooldown-setup.sh" --check 2>/dev/null || true
  else
    echo -e "  ${YELLOW}local-cooldown-setup.sh が見つかりません${NC}"
  fi
  echo ""

  # 3. IOC データベース
  echo -e "${CYAN}[3] IOC データベース${NC}"
  IOC_DIR="$HOME/.security-ioc"
  if [ -d "$IOC_DIR" ]; then
    hash_count=$(wc -l < "$IOC_DIR/malicious_hashes.txt" 2>/dev/null || echo "0")
    domain_count=$(wc -l < "$IOC_DIR/bad_domains.txt" 2>/dev/null || echo "0")
    echo -e "  ${GREEN}存在${NC}: ハッシュ ${hash_count} 件, ドメイン ${domain_count} 件"
    if [ -f "$IOC_DIR/update.log" ]; then
      last_update=$(tail -1 "$IOC_DIR/update.log" 2>/dev/null | head -c 19)
      echo -e "  最終更新: ${last_update}"
    fi
  else
    echo -e "  ${YELLOW}未初期化${NC}: ~/.security-ioc/ が存在しません"
  fi
  echo ""

  # 4. launchd ジョブ
  echo -e "${CYAN}[4] launchd ジョブ${NC}"
  for plist in "com.sample.security-check" "com.sample.threat-intel-update"; do
    if launchctl list 2>/dev/null | grep -q "$plist"; then
      echo -e "  ${GREEN}有効${NC}: $plist"
    elif [ -f "$HOME/Library/LaunchAgents/${plist}.plist" ]; then
      echo -e "  ${YELLOW}ファイル存在（未ロード）${NC}: $plist"
    else
      echo -e "  ${RED}未設定${NC}: $plist"
    fi
  done
  echo ""

  # 5. セキュリティ監査
  echo -e "${CYAN}[5] セキュリティ監査${NC}"
  if [ -f "$SCRIPT_DIR/claude-code-security-audit.sh" ]; then
    echo "  監査スクリプト: 利用可能"
    report_dir="$HOME/security-reports"
    if [ -d "$report_dir" ]; then
      latest=$(ls -t "$report_dir"/mac-check-*.md 2>/dev/null | head -1)
      if [ -n "$latest" ]; then
        echo -e "  最新レポート: $(basename "$latest")"
      fi
    fi
  fi

  exit 0
fi

# === セットアップ実行 ===
echo -e "${BOLD}=========================================="
echo " ホスト Mac セキュリティ統合セットアップ"
echo "==========================================${NC}"
echo ""
echo "このスクリプトは以下を実行します:"
echo "  1. Claude Code グローバル設定の強化"
echo "  2. パッケージマネージャのクールダウン設定"
echo "  3. IOC データベースの初期化"
echo "  4. 定期チェックの launchd ジョブ登録"
echo "  5. 初回セキュリティ監査"
echo ""

if [ "$MODE" != "--yes" ] && [ "$MODE" != "-y" ]; then
  echo -en "セットアップを開始しますか? [Y/n] "
  read -r answer
  case "$answer" in
    [nN]*) echo "中止しました"; exit 0 ;;
  esac
fi

# --- Step 1: Claude Code グローバル設定 ---
step "Claude Code グローバル設定の強化"
echo "  ~/.claude/settings.json に deny ルールを適用します"

if [ -f "$SCRIPT_DIR/global-claude-setup.sh" ]; then
  if confirm; then
    bash "$SCRIPT_DIR/global-claude-setup.sh" apply
    echo -e "  ${GREEN}完了${NC}"
  else
    echo -e "  ${YELLOW}スキップ${NC}"
  fi
else
  echo -e "  ${RED}global-claude-setup.sh が見つかりません${NC}"
fi

# --- Step 2: クールダウン設定 ---
step "パッケージマネージャのクールダウン設定"
echo "  npm, pip, uv の 7 日クールダウンを設定します"

if [ -f "$PROJECT_ROOT/cooldown_management/local-cooldown-setup.sh" ]; then
  if confirm; then
    if [ "$MODE" = "--yes" ] || [ "$MODE" = "-y" ]; then
      bash "$PROJECT_ROOT/cooldown_management/local-cooldown-setup.sh" --yes
    else
      bash "$PROJECT_ROOT/cooldown_management/local-cooldown-setup.sh"
    fi
    echo -e "  ${GREEN}完了${NC}"
  else
    echo -e "  ${YELLOW}スキップ${NC}"
  fi
else
  echo -e "  ${RED}local-cooldown-setup.sh が見つかりません${NC}"
fi

# --- Step 3: IOC データベース初期化 ---
step "IOC データベースの初期化"
echo "  脅威インテリジェンスデータを取得します（初回は数分かかります）"

IOC_DIR="$HOME/.security-ioc"
if [ -d "$IOC_DIR" ] && [ -f "$IOC_DIR/malicious_hashes.txt" ]; then
  echo -e "  ${GREEN}既に初期化済み${NC}"
  echo "  再取得する場合は手動で実行: bash $SCRIPT_DIR/threat-intel-updater.sh"
else
  if [ -f "$SCRIPT_DIR/threat-intel-updater.sh" ]; then
    if confirm; then
      bash "$SCRIPT_DIR/threat-intel-updater.sh"
      echo -e "  ${GREEN}完了${NC}"
    else
      echo -e "  ${YELLOW}スキップ${NC}"
    fi
  else
    echo -e "  ${RED}threat-intel-updater.sh が見つかりません${NC}"
  fi
fi

# --- Step 4: launchd ジョブ登録 ---
step "定期チェックの launchd ジョブ登録"
echo "  週次セキュリティチェック（月曜 9:00）と日次 IOC 更新（毎日 7:00）"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS_DIR"
mkdir -p "$HOME/security-reports"

register_plist() {
  local src="$1"
  local name
  name=$(basename "$src" .plist)
  local dst="$LAUNCH_AGENTS_DIR/${name}.plist"

  if [ ! -f "$src" ]; then
    echo -e "  ${RED}${name}: ソースファイルが見つかりません${NC}"
    return
  fi

  # __HOME__ プレースホルダーを実際のホームディレクトリに置換
  sed "s|__HOME__|$HOME|g" "$src" > "$dst"

  # 既にロード済みなら一度アンロード
  launchctl unload "$dst" 2>/dev/null || true
  launchctl load "$dst" 2>/dev/null || true

  echo -e "  ${GREEN}${name}: 登録完了${NC}"
}

if confirm; then
  register_plist "$SCRIPT_DIR/com.sample.security-check.plist"
  register_plist "$SCRIPT_DIR/com.sample.threat-intel-update.plist"
else
  echo -e "  ${YELLOW}スキップ${NC}"
fi

# --- Step 5: 初回セキュリティ監査 ---
step "初回セキュリティ監査"
echo "  Claude Code の設定状態を監査します"

if [ -f "$SCRIPT_DIR/claude-code-security-audit.sh" ]; then
  if confirm; then
    bash "$SCRIPT_DIR/claude-code-security-audit.sh" || true
    echo -e "  ${GREEN}完了${NC}"
  else
    echo -e "  ${YELLOW}スキップ${NC}"
  fi
else
  echo -e "  ${RED}claude-code-security-audit.sh が見つかりません${NC}"
fi

# === 完了 ===
echo ""
echo -e "${BOLD}=========================================="
echo " セットアップ完了"
echo "==========================================${NC}"
echo ""
echo "次のステップ:"
echo "  1. DevContainer を起動してください（QUICKSTART.md を参照）"
echo "  2. セキュリティ状態の確認:"
echo "     bash mac_security_check/setup.sh --check"
