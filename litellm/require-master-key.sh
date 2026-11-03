#!/bin/sh
# LITELLM_MASTER_KEY が空だと LiteLLM Proxy は認証なしで起動し、同一ホスト / Docker ネットワーク上の
# 任意のプロセスが登録済みの API キーを使えてしまう。未設定の場合は起動を拒否する。
if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  echo "ERROR: LITELLM_MASTER_KEY が未設定のため LiteLLM を起動しません（.env に設定してください）" >&2
  exit 1
fi
exec "$@"
