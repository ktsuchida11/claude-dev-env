#!/bin/bash
# install-claude.sh - Download and install Claude Code CLI (standalone) on first run
set -euo pipefail

if command -v claude &>/dev/null; then
  echo "Claude Code CLI already installed, skipping."
  exit 0
fi

echo "Installing Claude Code CLI (standalone)..."
# Docker内ではルートディレクトリからの実行でファイルシステム全体をスキャンしてしまうため
# 一時ディレクトリに移動してからインストールする
cd /tmp
curl -fsSL https://claude.ai/install.sh | bash
echo "Claude Code CLI installed successfully."
