#!/bin/bash
# =============================================================================
# DevContainer 内で .env.enc を復号するスクリプト
# postStartCommand から呼び出される
#
# 前提:
#   - /run/secrets/age-key に age 秘密鍵が配置されている
#     （start-devcontainer.sh が docker cp で注入）
#   - /workspace/.env.enc が存在する
#
# 動作:
#   1. /run/secrets/age-key がなければ復号スキップ
#   2. .env.enc を復号して .env を生成
#   3. /run/secrets/age-key を即座に削除（鍵をメモリ上から消去）
# =============================================================================

set -euo pipefail

ENV_ENC="/workspace/.env.enc"
ENV_FILE="/workspace/.env"
KEY_FILE="/run/secrets/age-key"

# 鍵ファイルが存在しない場合
if [ ! -f "$KEY_FILE" ]; then
    echo "[env-decrypt] $KEY_FILE が未配置 — .env.enc の復号をスキップ"
    if [ -f "$ENV_FILE" ]; then
        echo "[env-decrypt] 既存の .env を使用します"
    else
        echo "[env-decrypt] WARN: .env が存在しません。手動で作成してください"
    fi
    exit 0
fi

# .env.enc が存在しない場合
if [ ! -f "$ENV_ENC" ]; then
    echo "[env-decrypt] .env.enc が見つかりません — 復号スキップ"
    # 鍵ファイルは不要なので削除
    rm -f "$KEY_FILE"
    exit 0
fi

# sops コマンドの存在確認
if ! command -v sops >/dev/null 2>&1; then
    echo "[env-decrypt] ERROR: sops がインストールされていません"
    rm -f "$KEY_FILE"
    exit 1
fi

# 復号（鍵をファイルから読み取って環境変数経由で sops に渡す）
echo "[env-decrypt] .env.enc を復号中..."
if SOPS_AGE_KEY="$(cat "$KEY_FILE")" sops --decrypt --input-type dotenv --output-type dotenv "$ENV_ENC" > "$ENV_FILE" 2>/dev/null; then
    chmod 600 "$ENV_FILE"
    echo "[env-decrypt] OK: .env を復号しました"
else
    echo "[env-decrypt] ERROR: 復号に失敗しました（鍵が正しいか確認してください）"
    rm -f "$ENV_FILE"
fi

# 鍵ファイルを即座に削除（復号成功・失敗に関わらず）
rm -f "$KEY_FILE"
echo "[env-decrypt] 鍵ファイルを削除しました"
