#!/bin/bash
# install-claude.sh - Download and install Claude Code CLI (standalone) on first run
#
# CLAUDE_CODE_VERSION でバージョンを固定できる（サプライチェーン対策）。
#   latest  : 最新版（デフォルト）
#   stable  : 安定版チャネル
#   X.Y.Z   : 特定バージョン（例: 2.1.177）
set -euo pipefail

CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"

if command -v claude &>/dev/null; then
  echo "Claude Code CLI already installed, skipping."
  exit 0
fi

echo "Installing Claude Code CLI (standalone, version: ${CLAUDE_CODE_VERSION})..."
# Docker内ではルートディレクトリからの実行でファイルシステム全体をスキャンしてしまうため
# 一時ディレクトリに移動してからインストールする
cd /tmp
if [ "$CLAUDE_CODE_VERSION" = "latest" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
else
  curl -fsSL https://claude.ai/install.sh | bash -s -- "$CLAUDE_CODE_VERSION"
fi
echo "Claude Code CLI installed successfully."
