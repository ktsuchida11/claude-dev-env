#!/usr/bin/env bash
# =============================================================================
# linux-supply-chain-check.sh
# Linux (Amazon Linux 2023) 向けサプライチェーン攻撃チェッカー
#
# macOS 版 (mac-supply-chain-check-v2.sh) の Linux 対応版。
# 共通チェックは host_security/common-supply-chain-checks.sh を利用。
#
# 使い方:
#   bash linux_security_check/linux-supply-chain-check.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# プラットフォーム検出
source "$PROJECT_ROOT/host_security/platform-detect.sh"

DATE=$(date +"%Y-%m-%d_%H%M")
REPORT_DIR="$HOME/security-reports"
REPORT="$REPORT_DIR/linux-check-$DATE.md"
IOC_DIR="$HOME/.security-ioc"
ALERT_COUNT=0
CRITICAL_COUNT=0

mkdir -p "$REPORT_DIR"

# --- Helpers ---
section() { echo -e "\n## $1\n" >> "$REPORT"; }
ok()      { echo "- ✅ $1" >> "$REPORT"; }
warn()    { echo "- ⚠️  $1" >> "$REPORT"; ALERT_COUNT=$((ALERT_COUNT + 1)); }
critical(){ echo "- 🔴 **$1**" >> "$REPORT"; ALERT_COUNT=$((ALERT_COUNT + 1)); CRITICAL_COUNT=$((CRITICAL_COUNT + 1)); }
info()    { echo "- ℹ️  $1" >> "$REPORT"; }

# --- OS 情報 ---
OS_PRETTY="Unknown Linux"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-$ID $VERSION_ID}"
fi

cat > "$REPORT" <<EOF
# Linux サプライチェーン攻撃チェックレポート
**実行日時**: $(date "+%Y年%m月%d日 %H:%M")
**ホスト名**: $(hostname)
**OS**: ${OS_PRETTY} ($(uname -m))
**カーネル**: $(uname -r)
**IOC DB**: $([ -d "$IOC_DIR" ] && echo "あり" || echo "なし — threat-intel-updater.sh を先に実行してください")
EOF

# =============================================================================
# 1. Linux システム整合性
# =============================================================================
section "1. Linux システム整合性"

# SELinux
if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
    case "$SELINUX_STATUS" in
        Enforcing)  ok "SELinux: Enforcing（推奨）" ;;
        Permissive) warn "SELinux: Permissive — Enforcing を推奨" ;;
        Disabled)   warn "SELinux: 無効 — セキュリティリスクがあります" ;;
        *)          info "SELinux: $SELINUX_STATUS" ;;
    esac
else
    info "SELinux: getenforce コマンドなし（SELinux 未インストール）"
fi

# ファイアウォール
if command -v firewall-cmd &>/dev/null; then
    FW_STATE=$(firewall-cmd --state 2>/dev/null || echo "not running")
    if [ "$FW_STATE" = "running" ]; then
        ok "firewalld: 実行中"
        # デフォルトゾーン
        DEFAULT_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || echo "?")
        info "firewalld デフォルトゾーン: $DEFAULT_ZONE"
    else
        warn "firewalld: 停止中"
    fi
elif command -v iptables &>/dev/null; then
    IPTABLES_RULES=$(iptables -L -n 2>/dev/null | grep -c "^" || echo "0")
    if [ "$IPTABLES_RULES" -gt 10 ]; then
        ok "iptables: ルール設定あり (${IPTABLES_RULES} 行)"
    else
        warn "iptables: ルールが少ない — ファイアウォール設定を確認してください"
    fi
else
    warn "ファイアウォール: firewalld / iptables が見つかりません"
fi

# ディスク暗号化 (LUKS)
if command -v lsblk &>/dev/null; then
    CRYPT_DEVS=$(lsblk -o NAME,TYPE 2>/dev/null | grep -c "crypt" || echo "0")
    if [ "$CRYPT_DEVS" -gt 0 ]; then
        ok "LUKS 暗号化: ${CRYPT_DEVS} デバイス検出"
    else
        info "LUKS 暗号化デバイスなし（EC2 の場合は EBS 暗号化を確認）"
    fi
fi

# =============================================================================
# 2. systemd サービス監査
# =============================================================================
section "2. systemd サービス監査"

# ユーザーサービス
USER_SERVICES_DIR="$HOME/.config/systemd/user"
if [ -d "$USER_SERVICES_DIR" ]; then
    USER_SERVICES=$(find "$USER_SERVICES_DIR" -name "*.service" -type f 2>/dev/null || true)
    if [ -n "$USER_SERVICES" ]; then
        info "ユーザー systemd サービス:"
        echo "$USER_SERVICES" | while read -r SVC; do
            local SVC_NAME
            SVC_NAME=$(basename "$SVC")
            # zui-* は自前のサービスなので既知
            if echo "$SVC_NAME" | grep -qE "^zui-"; then
                ok "既知サービス: \`$SVC_NAME\`"
            else
                warn "確認が必要なユーザーサービス: \`$SVC_NAME\`"
            fi
        done
    else
        ok "ユーザー systemd サービスなし"
    fi
else
    info "~/.config/systemd/user/ なし"
fi

# 不審なシステムサービス（最近追加されたもの）
RECENT_SYSTEM_SERVICES=$(find /etc/systemd/system -name "*.service" -type f -mtime -7 2>/dev/null | head -10 || true)
if [ -n "$RECENT_SYSTEM_SERVICES" ]; then
    warn "過去7日以内に追加/変更されたシステムサービス:"
    echo "$RECENT_SYSTEM_SERVICES" | while read -r SVC; do
        echo "  - \`$(basename "$SVC")\` ($(portable_stat_mtime "$SVC"))" >> "$REPORT"
    done
else
    ok "システムサービスに最近の変更なし"
fi

# =============================================================================
# 3. パッケージマネージャ整合性
# =============================================================================
section "3. パッケージマネージャ整合性"

if command -v rpm &>/dev/null; then
    # RPM 署名検証（全パッケージは時間がかかるのでスキップ、
    # セキュリティ関連パッケージのみチェック）
    SECURITY_PKGS="openssl openssh curl wget"
    RPM_ISSUES=0
    for PKG in $SECURITY_PKGS; do
        if rpm -q "$PKG" &>/dev/null; then
            RPM_VERIFY=$(rpm -V "$PKG" 2>/dev/null || true)
            if [ -n "$RPM_VERIFY" ]; then
                warn "RPM 検証で差異: \`$PKG\`"
                echo '```' >> "$REPORT"
                echo "$RPM_VERIFY" | head -5 >> "$REPORT"
                echo '```' >> "$REPORT"
                RPM_ISSUES=$((RPM_ISSUES + 1))
            fi
        fi
    done
    [ "$RPM_ISSUES" -eq 0 ] && ok "セキュリティ関連パッケージの RPM 検証: 問題なし"
fi

if command -v dnf &>/dev/null; then
    # dnf リポジトリの GPG チェック
    REPOS_WITHOUT_GPG=$(grep -rl "gpgcheck=0" /etc/yum.repos.d/ 2>/dev/null || true)
    if [ -n "$REPOS_WITHOUT_GPG" ]; then
        warn "GPG チェックが無効なリポジトリ:"
        echo "$REPOS_WITHOUT_GPG" | while read -r REPO; do
            echo "  - \`$(basename "$REPO")\`" >> "$REPORT"
        done
    else
        ok "全リポジトリで GPG チェック有効"
    fi

    # 非公式リポジトリ
    NON_AMAZON_REPOS=$(grep -rl "^baseurl=" /etc/yum.repos.d/ 2>/dev/null | while read -r F; do
        grep "baseurl=" "$F" | grep -vE "amazonaws|amazonlinux|fedoraproject|centos|redhat" || true
    done)
    if [ -n "$NON_AMAZON_REPOS" ]; then
        warn "非公式リポジトリの URL が検出されました"
    else
        ok "リポジトリは公式ソースのみ"
    fi
fi

# =============================================================================
# 4. バイナリ検証
# =============================================================================
section "4. バイナリ検証"

# /usr/local/bin 内の RPM 非管理バイナリ
if command -v rpm &>/dev/null; then
    UNPACKAGED_BINS=0
    for BIN in /usr/local/bin/*; do
        [ -f "$BIN" ] || continue
        if ! rpm -qf "$BIN" &>/dev/null; then
            UNPACKAGED_BINS=$((UNPACKAGED_BINS + 1))
        fi
    done
    if [ "$UNPACKAGED_BINS" -gt 0 ]; then
        info "/usr/local/bin に RPM 非管理のバイナリ: ${UNPACKAGED_BINS}件"
    else
        ok "/usr/local/bin の全バイナリが RPM 管理下"
    fi
fi

# 最近変更されたバイナリ
section "5. 最近変更されたバイナリ (過去7日)"

RECENT_MODS=$(find /usr/local/bin /usr/bin 2>/dev/null -type f -mtime -7 2>/dev/null | head -20 || true)
[ -z "$RECENT_MODS" ] && ok "変更なし" || {
    info "過去7日間に変更:"
    echo "$RECENT_MODS" | while read -r F; do
        echo "  - \`$(basename "$F")\` ($(portable_stat_mtime "$F"))" >> "$REPORT"
    done
}

# =============================================================================
# 6. sudo / 権限監査 (macOS TCC の代替)
# =============================================================================
section "6. sudo / 権限監査"

# sudoers の NOPASSWD 設定
if [ -r /etc/sudoers ]; then
    NOPASSWD_ENTRIES=$(grep -r "NOPASSWD" /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -v "^#" || true)
    if [ -n "$NOPASSWD_ENTRIES" ]; then
        warn "NOPASSWD が設定されたエントリ:"
        echo "$NOPASSWD_ENTRIES" | while read -r LINE; do
            echo "  - \`$LINE\`" >> "$REPORT"
        done
    else
        ok "NOPASSWD エントリなし"
    fi
fi

# sudo グループのメンバー
SUDO_USERS=$(getent group wheel 2>/dev/null | cut -d: -f4 || getent group sudo 2>/dev/null | cut -d: -f4 || true)
if [ -n "$SUDO_USERS" ]; then
    info "sudo/wheel グループメンバー: $SUDO_USERS"
fi

# =============================================================================
# 共通チェック (platform-detect.sh + common-supply-chain-checks.sh)
# =============================================================================
source "$PROJECT_ROOT/host_security/common-supply-chain-checks.sh"
run_all_common_checks

# =============================================================================
# 前回レポートとの差分
# =============================================================================
section "前回レポートとの差分"

PREV_REPORT=$(ls -t "$REPORT_DIR"/linux-check-*.md 2>/dev/null | grep -v "$DATE" | head -1 || true)
if [ -n "$PREV_REPORT" ] && [ -f "$PREV_REPORT" ]; then
    PREV_ALERTS=$(grep -c "⚠️\|🔴" "$PREV_REPORT" 2>/dev/null || echo "0")
    info "前回レポート: $(basename "$PREV_REPORT") (アラート: ${PREV_ALERTS}件)"
else
    info "比較可能な前回レポートなし（初回実行）"
fi

# =============================================================================
# サマリー
# =============================================================================
echo -e "\n---\n" >> "$REPORT"
echo "## サマリー" >> "$REPORT"
echo "" >> "$REPORT"

if [ "$CRITICAL_COUNT" -gt 0 ]; then
    echo "🔴 **CRITICAL: ${CRITICAL_COUNT}件** — 即座の対応が必要です" >> "$REPORT"
elif [ "$ALERT_COUNT" -gt 0 ]; then
    echo "🟡 **アラート: ${ALERT_COUNT}件** — 上記 ⚠️ 項目を確認してください" >> "$REPORT"
else
    echo "🟢 **問題なし** — すべてのチェックをパスしました" >> "$REPORT"
fi

echo "" >> "$REPORT"
IOC_STATS=""
[ -d "$IOC_DIR" ] && IOC_STATS=" | IOC DB: $(ls "$IOC_DIR"/*.txt "$IOC_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')ファイル"
echo "_チェックエンジン: Linux v1${IOC_STATS}_" >> "$REPORT"

# --- 出力 ---
echo ""
echo "========================================"
if [ "$CRITICAL_COUNT" -gt 0 ]; then
    echo "  🔴 CRITICAL: ${CRITICAL_COUNT}件 / アラート合計: ${ALERT_COUNT}件"
else
    echo "  チェック完了 — アラート: ${ALERT_COUNT}件"
fi
echo "  レポート: $REPORT"
echo "========================================"
echo ""

# 通知
portable_notify "Security Check" "チェック完了 — アラート: ${ALERT_COUNT}件"
