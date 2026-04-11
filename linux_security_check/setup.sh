#!/usr/bin/env bash
# =============================================================================
# linux_security_check/setup.sh — Linux ホストセキュリティ統合セットアップ
#
# Amazon Linux 2023 / RHEL 系 / WSL2 向け。
# mac_security_check/setup.sh と同じ 5 ステップ構造。
#
# 実行内容:
#   1. Claude Code グローバル設定の強化（deny ルール適用）
#   2. パッケージマネージャのクールダウン設定（npm, pip, uv）
#   3. IOC データベースの初期化（オプション — --skip-ioc でスキップ可）
#   4. systemd タイマーの登録（定期チェック・IOC 更新）
#   5. 初回セキュリティ監査の実行
#
# 使い方:
#   bash linux_security_check/setup.sh          # 対話モード
#   bash linux_security_check/setup.sh --yes    # 全自動
#   bash linux_security_check/setup.sh --check  # 状態確認のみ
#   bash linux_security_check/setup.sh --skip-ioc  # IOC をスキップ
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# プラットフォーム検出
source "$PROJECT_ROOT/host_security/platform-detect.sh"

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MODE="--interactive"
SKIP_IOC=false
STEP=0
TOTAL=5

# 引数処理
for arg in "$@"; do
    case "$arg" in
        --yes|-y)       MODE="--yes" ;;
        --check|-c)     MODE="--check" ;;
        --skip-ioc)     SKIP_IOC=true ;;
        --interactive)  MODE="--interactive" ;;
    esac
done

step() {
    STEP=$((STEP + 1))
    echo ""
    echo -e "${BOLD}${CYAN}[Step ${STEP}/${TOTAL}]${NC} $1"
    echo "─────────────────────────────────────────"
}

confirm() {
    if [ "$MODE" = "--yes" ]; then
        return 0
    fi
    echo -en "  続行しますか? [Y/n] "
    read -r answer
    case "$answer" in
        [nN]*) return 1 ;;
        *) return 0 ;;
    esac
}

# =============================================================================
# チェックモード
# =============================================================================
if [ "$MODE" = "--check" ]; then
    echo -e "${BOLD}=== Linux ホストセキュリティ設定チェック ===${NC}"
    echo -e "  Distro: ${CYAN}${DISTRO}${NC} | Pkg: ${CYAN}${PKG_MANAGER}${NC} | Init: ${CYAN}${INIT_SYSTEM}${NC}"
    echo ""

    # 1. Claude Code グローバル設定
    echo -e "${CYAN}[1] Claude Code グローバル設定${NC}"
    if [ -f "$PROJECT_ROOT/mac_security_check/global-claude-setup.sh" ]; then
        bash "$PROJECT_ROOT/mac_security_check/global-claude-setup.sh" check 2>/dev/null || true
    else
        echo -e "  ${YELLOW}global-claude-setup.sh が見つかりません${NC}"
    fi
    echo ""

    # 2. クールダウン設定
    echo -e "${CYAN}[2] クールダウン設定${NC}"
    if [ -f "$PROJECT_ROOT/cooldown_management/cooldown-update.sh" ]; then
        bash "$PROJECT_ROOT/cooldown_management/cooldown-update.sh" --check 2>/dev/null || true
    else
        echo -e "  ${YELLOW}cooldown-update.sh が見つかりません${NC}"
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

    # 4. systemd タイマー
    echo -e "${CYAN}[4] systemd タイマー${NC}"
    SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
    for timer in "zui-security-check" "zui-threat-intel-update"; do
        if systemctl --user is-active "${timer}.timer" &>/dev/null 2>&1; then
            echo -e "  ${GREEN}有効${NC}: ${timer}.timer"
        elif [ -f "$SYSTEMD_USER_DIR/${timer}.timer" ]; then
            echo -e "  ${YELLOW}ファイル存在（未有効化）${NC}: ${timer}.timer"
        else
            echo -e "  ${RED}未設定${NC}: ${timer}.timer"
        fi
    done
    echo ""

    # 5. セキュリティ監査
    echo -e "${CYAN}[5] セキュリティ監査${NC}"
    if [ -f "$SCRIPT_DIR/claude-code-security-audit-linux.sh" ]; then
        echo "  監査スクリプト: 利用可能"
        report_dir="$HOME/security-reports"
        if [ -d "$report_dir" ]; then
            latest=$(ls -t "$report_dir"/linux-check-*.md 2>/dev/null | head -1)
            if [ -n "${latest:-}" ]; then
                echo -e "  最新レポート: $(basename "$latest")"
            fi
        fi
    fi

    exit 0
fi

# =============================================================================
# セットアップ実行
# =============================================================================
echo -e "${BOLD}=========================================="
echo " Linux ホストセキュリティ統合セットアップ"
echo "==========================================${NC}"
echo ""
echo -e "  Distro: ${CYAN}${DISTRO}${NC} | Pkg: ${CYAN}${PKG_MANAGER}${NC}"
echo ""
echo "このスクリプトは以下を実行します:"
echo "  1. Claude Code グローバル設定の強化"
echo "  2. パッケージマネージャのクールダウン設定"
if [ "$SKIP_IOC" = true ]; then
    echo "  3. IOC データベースの初期化 (スキップ)"
else
    echo "  3. IOC データベースの初期化"
fi
echo "  4. 定期チェックの systemd タイマー登録"
echo "  5. 初回セキュリティ監査"
echo ""

if [ "$MODE" != "--yes" ]; then
    echo -en "セットアップを開始しますか? [Y/n] "
    read -r answer
    case "$answer" in
        [nN]*) echo "中止しました"; exit 0 ;;
    esac
fi

# --- Step 1: Claude Code グローバル設定 ---
step "Claude Code グローバル設定の強化"
echo "  ~/.claude/settings.json に deny ルールを適用します"

GLOBAL_SETUP="$PROJECT_ROOT/mac_security_check/global-claude-setup.sh"
if [ -f "$GLOBAL_SETUP" ]; then
    if confirm; then
        bash "$GLOBAL_SETUP" apply
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

COOLDOWN_SETUP="$PROJECT_ROOT/cooldown_management/local-cooldown-setup.sh"
if [ -f "$COOLDOWN_SETUP" ]; then
    if confirm; then
        if [ "$MODE" = "--yes" ]; then
            bash "$COOLDOWN_SETUP" --yes
        else
            bash "$COOLDOWN_SETUP"
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

if [ "$SKIP_IOC" = true ]; then
    echo -e "  ${YELLOW}--skip-ioc が指定されたためスキップ${NC}"
else
    echo "  脅威インテリジェンスデータを取得します（初回は数分かかります）"

    IOC_DIR="$HOME/.security-ioc"
    THREAT_INTEL="$PROJECT_ROOT/mac_security_check/threat-intel-updater.sh"

    if [ -d "$IOC_DIR" ] && [ -f "$IOC_DIR/malicious_hashes.txt" ]; then
        echo -e "  ${GREEN}既に初期化済み${NC}"
        echo "  再取得する場合は手動で実行: bash $THREAT_INTEL"
    else
        if [ -f "$THREAT_INTEL" ]; then
            if confirm; then
                bash "$THREAT_INTEL"
                echo -e "  ${GREEN}完了${NC}"
            else
                echo -e "  ${YELLOW}スキップ${NC}"
            fi
        else
            echo -e "  ${RED}threat-intel-updater.sh が見つかりません${NC}"
        fi
    fi
fi

# --- Step 4: systemd タイマー登録 ---
step "定期チェックの systemd タイマー登録"
echo "  週次セキュリティチェック（月曜 9:00）と日次 IOC 更新（毎日 7:00）"

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
mkdir -p "$HOME/security-reports"

register_systemd_unit() {
    local src="$1"
    local name
    name=$(basename "$src")
    local dst="$SYSTEMD_USER_DIR/$name"

    if [ ! -f "$src" ]; then
        echo -e "  ${RED}${name}: ソースファイルが見つかりません${NC}"
        return
    fi

    # __HOME__ プレースホルダーを実際のホームディレクトリに置換
    sed "s|__HOME__|$HOME|g" "$src" > "$dst"
    echo -e "  ${GREEN}${name}: 配置完了${NC}"
}

if confirm; then
    # サービスとタイマーを配置
    register_systemd_unit "$SCRIPT_DIR/zui-security-check.service"
    register_systemd_unit "$SCRIPT_DIR/zui-security-check.timer"

    if [ "$SKIP_IOC" = false ]; then
        register_systemd_unit "$SCRIPT_DIR/zui-threat-intel-update.service"
        register_systemd_unit "$SCRIPT_DIR/zui-threat-intel-update.timer"
    fi

    # daemon-reload して有効化
    if systemctl --user daemon-reload 2>/dev/null; then
        systemctl --user enable --now zui-security-check.timer 2>/dev/null && \
            echo -e "  ${GREEN}zui-security-check.timer: 有効化完了${NC}" || \
            echo -e "  ${YELLOW}zui-security-check.timer: 有効化に失敗（loginctl enable-linger が必要な場合があります）${NC}"

        if [ "$SKIP_IOC" = false ]; then
            systemctl --user enable --now zui-threat-intel-update.timer 2>/dev/null && \
                echo -e "  ${GREEN}zui-threat-intel-update.timer: 有効化完了${NC}" || \
                echo -e "  ${YELLOW}zui-threat-intel-update.timer: 有効化に失敗${NC}"
        fi
    else
        echo -e "  ${YELLOW}systemctl --user が利用できません（WSL2 の場合は cron を使用してください）${NC}"
    fi
else
    echo -e "  ${YELLOW}スキップ${NC}"
fi

# --- Step 5: 初回セキュリティ監査 ---
step "初回セキュリティ監査"
echo "  Claude Code の設定状態を監査します"

AUDIT_SCRIPT="$SCRIPT_DIR/claude-code-security-audit-linux.sh"
if [ -f "$AUDIT_SCRIPT" ]; then
    if confirm; then
        bash "$AUDIT_SCRIPT" || true
        echo -e "  ${GREEN}完了${NC}"
    else
        echo -e "  ${YELLOW}スキップ${NC}"
    fi
else
    echo -e "  ${RED}claude-code-security-audit-linux.sh が見つかりません${NC}"
fi

# =============================================================================
# 完了
# =============================================================================
echo ""
echo -e "${BOLD}=========================================="
echo " セットアップ完了"
echo "==========================================${NC}"
echo ""
echo "次のステップ:"
echo "  1. DevContainer を起動してください（QUICKSTART.md を参照）"
echo "  2. 定期的に以下を実行してクールダウン日付を更新:"
echo "     bash cooldown_management/cooldown-update.sh"
echo "  3. セキュリティ状態の確認:"
echo "     bash host_security/setup.sh --check"
if [ "$SKIP_IOC" = true ]; then
    echo ""
    echo "  IOC データベースを後から有効化する場合:"
    echo "     bash mac_security_check/threat-intel-updater.sh"
fi
