#!/usr/bin/env bash
# =============================================================================
# platform-detect.sh — クロスプラットフォームユーティリティ
#
# source して使用する。OS/distro 検出とポータブルなラッパー関数を提供。
#
# 提供する変数:
#   PLATFORM   — "darwin" or "linux"
#   DISTRO     — "macos", "al2023", "ubuntu", "debian", "rhel", "unknown"
#   PKG_MANAGER — "brew", "dnf", "apt", "yum", "unknown"
#   INIT_SYSTEM — "launchd", "systemd", "unknown"
#
# 提供する関数:
#   portable_stat_perm <file>    — ファイルのパーミッション (例: 644)
#   portable_stat_owner <file>   — ファイルの所有者名
#   portable_stat_mtime <file>   — ファイルの最終更新日時
#   portable_stat_mtime_epoch <file> — 最終更新の UNIX epoch
#   portable_sha256 <file>       — SHA256 ハッシュ (ハッシュのみ出力)
#   portable_date_ago <days>     — N日前の日付 (YYYY-MM-DD)
#   portable_sed_i <expression> <file> — インプレース sed
#   portable_notify <title> <message> — デスクトップ通知 (失敗時は stdout)
#   portable_install_hint <pkg>  — パッケージインストールのヒント表示
#
# 使い方:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/platform-detect.sh"
# =============================================================================

# 二重読み込み防止
if [ "${_PLATFORM_DETECT_LOADED:-}" = "1" ]; then
    return 0 2>/dev/null || true
fi
_PLATFORM_DETECT_LOADED=1

# =============================================================================
# OS / Distro 検出
# =============================================================================
_detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "darwin" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

_detect_distro() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            if [ -f /etc/os-release ]; then
                # shellcheck disable=SC1091
                . /etc/os-release
                case "$ID" in
                    amzn)
                        if [ "${VERSION_ID:-}" = "2023" ]; then
                            echo "al2023"
                        else
                            echo "amzn"
                        fi
                        ;;
                    ubuntu)  echo "ubuntu" ;;
                    debian)  echo "debian" ;;
                    rhel|centos|rocky|alma) echo "rhel" ;;
                    fedora)  echo "fedora" ;;
                    *)       echo "$ID" ;;
                esac
            else
                echo "unknown"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

_detect_pkg_manager() {
    if command -v brew &>/dev/null; then
        echo "brew"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v yum &>/dev/null; then
        echo "yum"
    else
        echo "unknown"
    fi
}

_detect_init_system() {
    case "$(uname -s)" in
        Darwin) echo "launchd" ;;
        Linux)
            if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
                echo "systemd"
            else
                echo "unknown"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

PLATFORM=$(_detect_platform)
DISTRO=$(_detect_distro)
PKG_MANAGER=$(_detect_pkg_manager)
INIT_SYSTEM=$(_detect_init_system)

# =============================================================================
# ポータブルラッパー関数
# =============================================================================

# ファイルパーミッション (例: "644", "755")
portable_stat_perm() {
    local file="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        stat -f "%Lp" "$file" 2>/dev/null || echo "?"
    else
        stat -c "%a" "$file" 2>/dev/null || echo "?"
    fi
}

# ファイル所有者名
portable_stat_owner() {
    local file="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        stat -f "%Su" "$file" 2>/dev/null || echo "?"
    else
        stat -c "%U" "$file" 2>/dev/null || echo "?"
    fi
}

# ファイル最終更新日時 (人間可読)
portable_stat_mtime() {
    local file="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$file" 2>/dev/null || echo "?"
    else
        stat -c '%y' "$file" 2>/dev/null | cut -d'.' -f1 || echo "?"
    fi
}

# ファイル最終更新の UNIX epoch
portable_stat_mtime_epoch() {
    local file="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        stat -f "%m" "$file" 2>/dev/null || echo "0"
    else
        stat -c "%Y" "$file" 2>/dev/null || echo "0"
    fi
}

# SHA256 ハッシュ (ハッシュ文字列のみ出力)
portable_sha256() {
    local file="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
    else
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    fi
}

# N日前の日付 (YYYY-MM-DD, UTC)
portable_date_ago() {
    local days="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        date -u -v-${days}d +%Y-%m-%d
    else
        date -u -d "$days days ago" +%Y-%m-%d
    fi
}

# 日付文字列 → epoch 変換
portable_date_to_epoch() {
    local date_str="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        date -jf "%Y-%m-%d" "$date_str" +%s 2>/dev/null || echo "0"
    else
        date -d "$date_str" +%s 2>/dev/null || echo "0"
    fi
}

# インプレース sed
portable_sed_i() {
    local expression="$1"
    local file="$2"
    if [ "$PLATFORM" = "darwin" ]; then
        sed -i '' "$expression" "$file"
    else
        sed -i "$expression" "$file"
    fi
}

# デスクトップ通知 (失敗時は stdout にフォールバック)
portable_notify() {
    local title="$1"
    local message="$2"
    if [ "$PLATFORM" = "darwin" ]; then
        osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
    elif command -v notify-send &>/dev/null; then
        notify-send "$title" "$message" 2>/dev/null || true
    else
        echo "[$title] $message"
    fi
}

# パッケージインストールのヒント
portable_install_hint() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        brew) echo "brew install $pkg" ;;
        dnf)  echo "sudo dnf install -y $pkg" ;;
        apt)  echo "sudo apt-get install -y $pkg" ;;
        yum)  echo "sudo yum install -y $pkg" ;;
        *)    echo "パッケージマネージャで $pkg をインストールしてください" ;;
    esac
}

# ネットワーク接続の取得 (ESTABLISHED)
portable_net_connections() {
    if command -v ss &>/dev/null && [ "$PLATFORM" = "linux" ]; then
        ss -tnp 2>/dev/null | grep ESTAB || true
    else
        lsof -i -nP 2>/dev/null | grep ESTABLISHED || true
    fi
}

# pip.conf のパス
portable_pip_conf_path() {
    if [ "$PLATFORM" = "darwin" ]; then
        echo "$HOME/Library/Application Support/pip/pip.conf"
    else
        echo "$HOME/.config/pip/pip.conf"
    fi
}

# AI ツール設定パスのリスト (Cursor など OS で異なるもの)
portable_ai_config_paths() {
    local paths=(
        "$HOME/.claude"
        "$HOME/.claude.json"
        "$HOME/.config/claude"
        "$HOME/.cursor"
        "$HOME/.config/github-copilot"
        "$HOME/.anthropic"
        "$HOME/.openai"
        "$HOME/.config/gh"
    )
    # macOS 固有パス
    if [ "$PLATFORM" = "darwin" ]; then
        paths+=("$HOME/Library/Application Support/Cursor")
    else
        paths+=("$HOME/.config/cursor")
    fi
    printf '%s\n' "${paths[@]}"
}

# MCP 設定ファイルパスのリスト
portable_mcp_config_paths() {
    local paths=(
        "$HOME/.claude/mcp_config.json"
        "$HOME/.config/claude/mcp_config.json"
        "$HOME/.claude.json"
    )
    if [ "$PLATFORM" = "darwin" ]; then
        paths+=("$HOME/Library/Application Support/Claude/claude_desktop_config.json")
    else
        paths+=("$HOME/.config/claude/claude_desktop_config.json")
    fi
    printf '%s\n' "${paths[@]}"
}

# Keychain 操作: 保存
keychain_store() {
    local service="$1"
    local value="$2"
    if [ "$PLATFORM" = "darwin" ]; then
        security add-generic-password \
            -a "$USER" \
            -s "$service" \
            -w "$value" \
            -T "" \
            -U 2>/dev/null
    elif command -v aws &>/dev/null && aws sts get-caller-identity &>/dev/null 2>&1; then
        # AWS Secrets Manager (AL2023 優先)
        if aws secretsmanager describe-secret --secret-id "$service" &>/dev/null 2>&1; then
            aws secretsmanager put-secret-value \
                --secret-id "$service" \
                --secret-string "$value" >/dev/null
        else
            aws secretsmanager create-secret \
                --name "$service" \
                --secret-string "$value" >/dev/null
        fi
    elif command -v secret-tool &>/dev/null; then
        # libsecret (WSL2/Ubuntu)
        echo "$value" | secret-tool store \
            --label="Claude DevContainer key" \
            service "$service" \
            account "age-secret-key"
    else
        # ファイルベースフォールバック
        local keydir="$HOME/.config/age"
        mkdir -p "$keydir"
        chmod 700 "$keydir"
        printf '%s' "$value" > "$keydir/key.txt"
        chmod 600 "$keydir/key.txt"
        echo "[WARN] Keychain が利用できないため、$keydir/key.txt に保存しました（権限 600）"
    fi
}

# Keychain 操作: 取得
keychain_get() {
    local service="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        security find-generic-password \
            -a "$USER" \
            -s "$service" \
            -w 2>/dev/null
    elif command -v aws &>/dev/null && aws sts get-caller-identity &>/dev/null 2>&1; then
        aws secretsmanager get-secret-value \
            --secret-id "$service" \
            --query SecretString \
            --output text 2>/dev/null
    elif command -v secret-tool &>/dev/null; then
        secret-tool lookup \
            service "$service" \
            account "age-secret-key" 2>/dev/null
    elif [ -f "$HOME/.config/age/key.txt" ]; then
        cat "$HOME/.config/age/key.txt" 2>/dev/null
    else
        return 1
    fi
}

# Keychain 操作: 存在確認
keychain_exists() {
    local service="$1"
    keychain_get "$service" >/dev/null 2>&1
}

# Keychain バックエンド名を表示
keychain_backend_name() {
    if [ "$PLATFORM" = "darwin" ]; then
        echo "macOS Keychain"
    elif command -v aws &>/dev/null && aws sts get-caller-identity &>/dev/null 2>&1; then
        echo "AWS Secrets Manager"
    elif command -v secret-tool &>/dev/null; then
        echo "libsecret (secret-tool)"
    elif [ -f "$HOME/.config/age/key.txt" ]; then
        echo "ファイルベース (~/.config/age/key.txt)"
    else
        echo "未設定"
    fi
}
