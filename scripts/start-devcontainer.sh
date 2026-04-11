#!/bin/bash
# =============================================================================
# DevContainer 起動ラッパー
#
# Keychain から age 秘密鍵を取得し、tmpfs 経由でコンテナに渡す。
# 環境変数には秘密鍵を残さない（docker cp → 復号 → 即削除）。
#
# 使い方:
#   bash scripts/start-devcontainer.sh                    # LiteLLM あり
#   bash scripts/start-devcontainer.sh --without-litellm  # LiteLLM なし
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KEYCHAIN_SERVICE="claude-devcontainer-age-key"
COMPOSE_FILE="docker-compose.yml"

# 引数処理
for arg in "$@"; do
    case "$arg" in
        --without-litellm)
            COMPOSE_FILE="docker-compose-without-litellm.yml"
            ;;
    esac
done

# Keychain から age 秘密鍵を取得（platform-detect.sh を利用）
PLATFORM_DETECT="$SCRIPT_DIR/../host_security/platform-detect.sh"
AGE_SECRET_KEY=""

if [ -f "$PLATFORM_DETECT" ]; then
    # shellcheck disable=SC1090
    source "$PLATFORM_DETECT"
    AGE_SECRET_KEY=$(keychain_get "$KEYCHAIN_SERVICE" 2>/dev/null || true)
else
    # フォールバック: platform-detect.sh がない場合は従来の検出
    OS=$(uname -s)
    if [ "$OS" = "Darwin" ]; then
        AGE_SECRET_KEY=$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
    elif [ "$OS" = "Linux" ]; then
        if command -v aws &>/dev/null && aws sts get-caller-identity &>/dev/null 2>&1; then
            AGE_SECRET_KEY=$(aws secretsmanager get-secret-value --secret-id "$KEYCHAIN_SERVICE" --query SecretString --output text 2>/dev/null || true)
        elif command -v secret-tool &>/dev/null; then
            AGE_SECRET_KEY=$(secret-tool lookup service "$KEYCHAIN_SERVICE" account "age-secret-key" 2>/dev/null || true)
        elif [ -f "$HOME/.config/age/key.txt" ]; then
            AGE_SECRET_KEY=$(cat "$HOME/.config/age/key.txt" 2>/dev/null || true)
        fi
    fi
fi

HAS_KEY=false
if [ -n "$AGE_SECRET_KEY" ]; then
    HAS_KEY=true
    echo "[start] age 秘密鍵を Keychain から取得しました"
else
    echo "[start] Keychain に age 秘密鍵がありません — 暗号化なしで起動します"
    echo "[start] セットアップ: bash scripts/setup-env-encryption.sh"
fi

# docker compose up
cd "$PROJECT_ROOT"
echo "[start] docker compose -f $COMPOSE_FILE up -d"
docker compose -f "$COMPOSE_FILE" up -d

# 鍵がある場合、docker cp で tmpfs に注入
if [ "$HAS_KEY" = true ]; then
    # dev コンテナ名を取得
    DEV_CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps -q dev 2>/dev/null)

    if [ -z "$DEV_CONTAINER" ]; then
        echo "[start] WARN: dev コンテナが見つかりません — 鍵の注入をスキップ"
    else
        # 一時ファイルに鍵を書き出し（ホスト側 tmpfs）
        TMPKEY=$(mktemp "${TMPDIR:-/tmp}/age-key.XXXXXX")
        printf '%s' "$AGE_SECRET_KEY" > "$TMPKEY"
        chmod 600 "$TMPKEY"

        # docker cp でコンテナの tmpfs に注入
        docker cp "$TMPKEY" "${DEV_CONTAINER}:/run/secrets/age-key"
        docker exec "$DEV_CONTAINER" chmod 600 /run/secrets/age-key
        docker exec "$DEV_CONTAINER" chown node:node /run/secrets/age-key

        # ホスト側の一時ファイルを安全に削除
        dd if=/dev/zero of="$TMPKEY" bs=$(wc -c < "$TMPKEY") count=1 2>/dev/null || true
        rm -f "$TMPKEY"

        echo "[start] 鍵をコンテナの /run/secrets/age-key に配置しました"
        echo "[start] postStartCommand (decrypt-env.sh) が復号後に自動削除します"
    fi

    # メモリ上の変数もクリア
    AGE_SECRET_KEY=""
fi

echo "[start] 完了"
