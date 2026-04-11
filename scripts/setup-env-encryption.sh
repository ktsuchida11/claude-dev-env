#!/bin/bash
# =============================================================================
# .env 暗号化セットアップスクリプト（ホスト Mac / Linux 用）
#
# 機能:
#   1. SOPS + age のインストール確認
#   2. age 鍵ペアの生成
#   3. 秘密鍵を OS Keychain に格納（ファイルシステムから排除）
#   4. .sops.yaml の生成
#   5. .env → .env.enc への暗号化
#   6. .env.example の生成（キー名のみ、値は空）
#
# 使い方:
#   bash scripts/setup-env-encryption.sh          # 初回セットアップ
#   bash scripts/setup-env-encryption.sh --check  # 状態確認のみ
#   bash scripts/setup-env-encryption.sh encrypt  # .env を再暗号化
#   bash scripts/setup-env-encryption.sh decrypt  # .env.enc を復号
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KEYCHAIN_SERVICE="claude-devcontainer-age-key"
AGE_KEY_FILE="${TMPDIR:-/tmp}/age-key-$$.txt"

# 色付き出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

cleanup() {
    # 一時ファイルの安全な削除
    if [ -f "$AGE_KEY_FILE" ]; then
        # 上書きしてから削除
        dd if=/dev/zero of="$AGE_KEY_FILE" bs=1 count=256 2>/dev/null || true
        rm -f "$AGE_KEY_FILE"
    fi
}
trap cleanup EXIT

# =============================================================================
# プラットフォーム検出 + Keychain 操作
# =============================================================================
PLATFORM_DETECT="$(cd "$(dirname "$0")" && pwd)/../host_security/platform-detect.sh"
if [ -f "$PLATFORM_DETECT" ]; then
    # shellcheck disable=SC1090
    source "$PLATFORM_DETECT"
    OS="$PLATFORM"
    # platform-detect.sh の keychain 関数をラップ
    _keychain_store() { keychain_store "$KEYCHAIN_SERVICE" "$1"; }
    _keychain_get()   { keychain_get "$KEYCHAIN_SERVICE"; }
    _keychain_exists(){ keychain_exists "$KEYCHAIN_SERVICE"; }
else
    # フォールバック: platform-detect.sh がない場合は従来の検出
    detect_os() {
        case "$(uname -s)" in
            Darwin) echo "mac" ;;
            Linux)  echo "linux" ;;
            *)      echo "unknown" ;;
        esac
    }
    OS=$(detect_os)

    _keychain_store() {
        local key="$1"
        if [ "$OS" = "mac" ]; then
            security add-generic-password \
                -a "$USER" \
                -s "$KEYCHAIN_SERVICE" \
                -w "$key" \
                -T "" \
                -U 2>/dev/null
        elif [ "$OS" = "linux" ]; then
            # フォールバック: secret-tool → ファイルベース
            if command -v aws &>/dev/null && aws sts get-caller-identity &>/dev/null 2>&1; then
                if aws secretsmanager describe-secret --secret-id "$KEYCHAIN_SERVICE" &>/dev/null 2>&1; then
                    aws secretsmanager put-secret-value \
                        --secret-id "$KEYCHAIN_SERVICE" \
                        --secret-string "$key" >/dev/null
                else
                    aws secretsmanager create-secret \
                        --name "$KEYCHAIN_SERVICE" \
                        --secret-string "$key" >/dev/null
                fi
            elif command -v secret-tool &>/dev/null; then
                echo "$key" | secret-tool store \
                    --label="Claude DevContainer age key" \
                    service "$KEYCHAIN_SERVICE" \
                    account "age-secret-key"
            else
                local keydir="$HOME/.config/age"
                mkdir -p "$keydir" && chmod 700 "$keydir"
                printf '%s' "$key" > "$keydir/key.txt"
                chmod 600 "$keydir/key.txt"
                warn "Keychain が利用できないため $keydir/key.txt に保存しました"
            fi
        else
            error "未対応の OS: $(uname -s)"
            return 1
        fi
    }

    _keychain_get() {
        if [ "$OS" = "mac" ]; then
            security find-generic-password \
                -a "$USER" \
                -s "$KEYCHAIN_SERVICE" \
                -w 2>/dev/null
        elif [ "$OS" = "linux" ]; then
            if command -v aws &>/dev/null && aws sts get-caller-identity &>/dev/null 2>&1; then
                aws secretsmanager get-secret-value \
                    --secret-id "$KEYCHAIN_SERVICE" \
                    --query SecretString \
                    --output text 2>/dev/null
            elif command -v secret-tool &>/dev/null; then
                secret-tool lookup \
                    service "$KEYCHAIN_SERVICE" \
                    account "age-secret-key" 2>/dev/null
            elif [ -f "$HOME/.config/age/key.txt" ]; then
                cat "$HOME/.config/age/key.txt" 2>/dev/null
            else
                return 1
            fi
        else
            return 1
        fi
    }

    _keychain_exists() { _keychain_get >/dev/null 2>&1; }
fi

# =============================================================================
# ツール存在確認
# =============================================================================
check_tools() {
    local missing=0

    if command -v sops >/dev/null 2>&1; then
        ok "sops $(sops --version 2>&1 | head -1)"
    else
        warn "sops が未インストール"
        missing=1
    fi

    if command -v age >/dev/null 2>&1; then
        ok "age $(age --version 2>&1)"
    else
        warn "age が未インストール"
        missing=1
    fi

    if command -v age-keygen >/dev/null 2>&1; then
        ok "age-keygen 利用可能"
    else
        warn "age-keygen が未インストール"
        missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        echo ""
        if [ "$OS" = "mac" ]; then
            info "インストール: brew install sops age"
        elif [ "$OS" = "linux" ]; then
            local _distro="${DISTRO:-unknown}"
            if [ "$_distro" = "al2023" ] || [ "$_distro" = "rhel" ] || [ "$_distro" = "fedora" ]; then
                info "age: https://github.com/FiloSottile/age/releases からダウンロード"
                info "sops: https://github.com/getsops/sops/releases からダウンロード"
            else
                info "age: sudo apt install age"
                info "sops: https://github.com/getsops/sops/releases からダウンロード"
            fi
        fi
        return 1
    fi
    return 0
}

# =============================================================================
# 状態チェック
# =============================================================================
check_status() {
    echo "=== .env 暗号化ステータス ==="
    echo ""

    # ツール
    echo "--- ツール ---"
    check_tools || true
    echo ""

    # Keychain
    echo "--- Keychain ---"
    if _keychain_exists; then
        ok "age 秘密鍵が Keychain に格納済み (service: $KEYCHAIN_SERVICE)"
    else
        warn "age 秘密鍵が Keychain に未格納"
    fi
    echo ""

    # ファイル状態
    echo "--- ファイル ---"
    if [ -f "$PROJECT_ROOT/.env.enc" ]; then
        ok ".env.enc 存在（暗号化済み）"
    else
        warn ".env.enc なし"
    fi

    if [ -f "$PROJECT_ROOT/.env" ]; then
        # .env が暗号化されているか平文か判定
        if head -3 "$PROJECT_ROOT/.env" | grep -q "sops_\|ENC\[AES"; then
            warn ".env は SOPS 暗号化済み（通常は .env.enc を使用）"
        else
            warn ".env は平文（暗号化を推奨）"
        fi
    else
        info ".env なし"
    fi

    if [ -f "$PROJECT_ROOT/.env.example" ]; then
        ok ".env.example 存在"
    else
        warn ".env.example なし"
    fi

    if [ -f "$PROJECT_ROOT/.sops.yaml" ]; then
        ok ".sops.yaml 存在"
    else
        warn ".sops.yaml なし"
    fi

    # ファイル権限チェック
    echo ""
    echo "--- ファイル権限 ---"
    for f in .env .env.enc .env.example; do
        if [ -f "$PROJECT_ROOT/$f" ]; then
            local perms
            perms=$(stat -f "%Lp" "$PROJECT_ROOT/$f" 2>/dev/null || stat -c "%a" "$PROJECT_ROOT/$f" 2>/dev/null)
            if [ "$perms" = "600" ]; then
                ok "$f: $perms (所有者のみ)"
            else
                warn "$f: $perms (推奨: 600)"
            fi
        fi
    done
}

# =============================================================================
# age 鍵の生成と Keychain 格納
# =============================================================================
setup_key() {
    if _keychain_exists; then
        info "age 秘密鍵は既に Keychain に格納されています"
        read -p "上書きしますか？ (y/N): " answer
        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            info "スキップ"
            return 0
        fi
    fi

    info "age 鍵ペアを生成中..."
    age-keygen -o "$AGE_KEY_FILE" 2>/dev/null

    # 公開鍵を抽出
    local public_key
    public_key=$(grep "^# public key:" "$AGE_KEY_FILE" | sed 's/^# public key: //')

    # 秘密鍵を抽出
    local secret_key
    secret_key=$(grep "^AGE-SECRET-KEY" "$AGE_KEY_FILE")

    # Keychain に格納
    info "秘密鍵を Keychain に格納中..."
    _keychain_store "$secret_key"
    ok "秘密鍵を Keychain に格納しました (service: $KEYCHAIN_SERVICE)"

    # 一時ファイルを安全に削除（trap でも削除されるが、早期に消す）
    dd if=/dev/zero of="$AGE_KEY_FILE" bs=1 count=256 2>/dev/null || true
    rm -f "$AGE_KEY_FILE"

    # 公開鍵を表示
    echo ""
    ok "公開鍵: $public_key"
    echo ""
    info "この公開鍵は .sops.yaml に記録されます"

    # .sops.yaml を生成
    cat > "$PROJECT_ROOT/.sops.yaml" << EOF
# SOPS 設定 — age 公開鍵で暗号化
# 秘密鍵は OS Keychain に格納（ファイルシステム上に残さない）
creation_rules:
  - path_regex: \.env$
    age: >-
      ${public_key}
EOF
    ok ".sops.yaml を生成しました"

    # ファイル権限を設定
    chmod 600 "$PROJECT_ROOT/.sops.yaml"
}

# =============================================================================
# .env → .env.enc 暗号化
# =============================================================================
encrypt_env() {
    if [ ! -f "$PROJECT_ROOT/.env" ]; then
        error ".env が見つかりません"
        return 1
    fi

    if [ ! -f "$PROJECT_ROOT/.sops.yaml" ]; then
        error ".sops.yaml が見つかりません。先に初期セットアップを実行してください"
        return 1
    fi

    # 一時的に age 鍵ファイルを作成（SOPS が必要とする）
    local secret_key
    secret_key=$(_keychain_get) || {
        error "Keychain から秘密鍵を取得できません。先にセットアップを実行してください"
        return 1
    }

    # SOPS_AGE_KEY 環境変数で渡す（ファイル不要）
    info ".env を暗号化中..."
    SOPS_AGE_KEY="$secret_key" sops --encrypt \
        --input-type dotenv \
        --output-type dotenv \
        "$PROJECT_ROOT/.env" > "$PROJECT_ROOT/.env.enc"

    chmod 600 "$PROJECT_ROOT/.env.enc"
    ok ".env.enc を生成しました"

    # .env.example を生成（キー名のみ、値は空）
    info ".env.example を生成中..."
    sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1=/' "$PROJECT_ROOT/.env" | \
        grep -v '^#.*[Ss]ecret\|^#.*[Kk]ey\|^#.*[Pp]ass' > "$PROJECT_ROOT/.env.example"
    chmod 644 "$PROJECT_ROOT/.env.example"
    ok ".env.example を生成しました"

    echo ""
    warn "平文の .env を削除することを推奨します:"
    echo "  rm .env"
    echo ""
    info "復号が必要な場合:"
    echo "  bash scripts/setup-env-encryption.sh decrypt"
}

# =============================================================================
# .env.enc → .env 復号
# =============================================================================
decrypt_env() {
    if [ ! -f "$PROJECT_ROOT/.env.enc" ]; then
        error ".env.enc が見つかりません"
        return 1
    fi

    local secret_key
    secret_key=$(_keychain_get) || {
        error "Keychain から秘密鍵を取得できません"
        return 1
    }

    info ".env.enc を復号中..."
    SOPS_AGE_KEY="$secret_key" sops --decrypt \
        --input-type dotenv \
        --output-type dotenv \
        "$PROJECT_ROOT/.env.enc" > "$PROJECT_ROOT/.env"

    chmod 600 "$PROJECT_ROOT/.env"
    ok ".env を復号しました"
}

# =============================================================================
# SOPS_AGE_KEY をエクスポート（docker-compose 用）
# =============================================================================
export_key() {
    local secret_key
    secret_key=$(_keychain_get) || {
        error "Keychain から秘密鍵を取得できません"
        return 1
    }
    echo "$secret_key"
}

# =============================================================================
# メイン
# =============================================================================
case "${1:-}" in
    --check|-c)
        check_status
        ;;
    encrypt|-e)
        encrypt_env
        ;;
    decrypt|-d)
        decrypt_env
        ;;
    export-key)
        export_key
        ;;
    --help|-h)
        echo "使い方: $0 [コマンド]"
        echo ""
        echo "コマンド:"
        echo "  (なし)      初回セットアップ（鍵生成 + Keychain 格納 + 暗号化）"
        echo "  --check     状態確認"
        echo "  encrypt     .env を暗号化して .env.enc を生成"
        echo "  decrypt     .env.enc を復号して .env を生成"
        echo "  export-key  Keychain から age 秘密鍵を出力（docker-compose 連携用）"
        echo "  --help      このヘルプ"
        ;;
    *)
        echo "=== .env 暗号化セットアップ ==="
        echo ""

        # Step 1: ツール確認
        info "Step 1: ツール確認"
        if ! check_tools; then
            error "必要なツールをインストールしてから再実行してください"
            exit 1
        fi
        echo ""

        # Step 2: 鍵生成 + Keychain 格納
        info "Step 2: age 鍵の生成と Keychain 格納"
        setup_key
        echo ""

        # Step 3: .env が存在すれば暗号化
        if [ -f "$PROJECT_ROOT/.env" ]; then
            info "Step 3: .env の暗号化"
            read -p ".env を暗号化しますか？ (Y/n): " answer
            if [ "$answer" != "n" ] && [ "$answer" != "N" ]; then
                encrypt_env
            fi
        else
            info "Step 3: .env が存在しないためスキップ"
            info ".env を作成後に以下を実行してください:"
            echo "  bash scripts/setup-env-encryption.sh encrypt"
        fi

        echo ""
        ok "セットアップ完了！"
        echo ""
        echo "--- 次のステップ ---"
        echo "1. DevContainer 起動時に自動で .env.enc が復号されます"
        echo "2. .env を編集した場合は再暗号化してください:"
        echo "   bash scripts/setup-env-encryption.sh encrypt"
        echo "3. .env.enc は git にコミットできます（暗号化済み）"
        ;;
esac
