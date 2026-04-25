#!/usr/bin/env bash
# block-dangerous.sh — PreToolUse Hook for Bash commands
# Exit 0 = allow, Exit 2 = block
#
# settings.json の deny ルールを補完する追加の防御レイヤー。
# deny ルールはパターンマッチベースのため、パイプやサブシェルで
# バイパスされる可能性がある。このスクリプトで追加チェックを行う。

set -euo pipefail

# stdin から tool_input を読み取る
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# --- 破壊的コマンドのパターン検出 ---

# rm -rf with dangerous targets (/, ~, $HOME, ..) — 完全ブロック
# rm 自体は settings.json の allow に含まれていないため、ユーザー確認プロンプトが出る
# /workspace/... 等の安全なパスは許可（末尾または後続がスペースの場合のみブロック）
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)*(\/(\s|$)|~|(\$HOME|\$\{HOME\})|\.\.)'; then
  echo '{"decision": "block", "reason": "Blocked: rm with dangerous target path (/, ~, $HOME, ..)"}' >&2
  exit 2
fi

# --- 以下はユーザー確認プロンプトをバイパスできる手段のため全面ブロック ---

# unlink（rm の代替コマンド、確認プロンプトを回避できる）
if echo "$COMMAND" | grep -qE '\bunlink\s'; then
  echo '{"decision": "block", "reason": "Blocked: unlink bypasses user confirmation. Use rm instead (requires user approval)."}' >&2
  exit 2
fi

# curl/wget through pipes or subshells (bypass attempt)
if echo "$COMMAND" | grep -qE '(curl|wget)\s'; then
  echo '{"decision": "block", "reason": "Blocked: curl/wget is not allowed in this environment"}' >&2
  exit 2
fi

# Network tools through pipes
if echo "$COMMAND" | grep -qE '(nc|ncat|telnet|socat)\s'; then
  echo '{"decision": "block", "reason": "Blocked: network tools are not allowed"}' >&2
  exit 2
fi

# Reverse shell patterns
if echo "$COMMAND" | grep -qE '(bash|sh|zsh)\s+-i.*>/dev/tcp'; then
  echo '{"decision": "block", "reason": "Blocked: reverse shell pattern detected"}' >&2
  exit 2
fi

# Base64 decode piped to shell (common obfuscation)
if echo "$COMMAND" | grep -qE 'base64.*-d.*\|\s*(bash|sh|zsh|python|node)'; then
  echo '{"decision": "block", "reason": "Blocked: base64 decode to shell execution"}' >&2
  exit 2
fi

# Credential file access through cat/less/more with pipes
if echo "$COMMAND" | grep -qE 'cat.*(\.env|credentials|\.ssh|\.aws|\.gnupg|id_rsa|\.pem)'; then
  echo '{"decision": "block", "reason": "Blocked: credential file access attempt"}' >&2
  exit 2
fi

# Environment variable exfiltration
if echo "$COMMAND" | grep -qE '(printenv|env)\s*\|.*(curl|wget|nc|python|node)'; then
  echo '{"decision": "block", "reason": "Blocked: environment variable exfiltration attempt"}' >&2
  exit 2
fi

# gh CLI の危険サブコマンド
# - gh api: 認証済みトークンによる任意 HTTP（repo 横断書込の濫用経路）
# - gh auth token: トークン平文出力（ログ・他プロセスへの漏洩）
# - gh auth login/logout/refresh: 認証状態の操作
# - gh secret / variable: repo secret/variable の読取・変更
# - gh workflow run/enable/disable: CI 任意起動・状態変更（CI 経由 RCE）
# - gh ssh-key / gpg-key: 永続化鍵の追加
if echo "$COMMAND" | grep -qE '\bgh\s+(api|secret|variable|ssh-key|gpg-key)\b|\bgh\s+auth\s+(token|login|logout|refresh)\b|\bgh\s+workflow\s+(run|enable|disable)\b'; then
  echo '{"decision": "block", "reason": "Blocked: dangerous gh subcommand (api / auth token / secret / variable / workflow run / ssh-key / gpg-key)"}' >&2
  exit 2
fi

# chmod: world-writable / setuid (u+s, 4xxx) / setgid (g+s, 2xxx) / sticky+SUID+SGID (6xxx) / -R 再帰
# シンボリック (+s) も数値 (4755 等) も両対応。setuid バイナリ作成は権限昇格の直接経路
if echo "$COMMAND" | grep -qE 'chmod\s+([ug]?\+s|777|666|-R\s+(777|666)|[2467][0-7]{3})(\s|$)'; then
  echo '{"decision": "block", "reason": "Blocked: chmod with overly permissive or setuid/setgid mode is not allowed"}' >&2
  exit 2
fi

# find -delete / find -exec rm（確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE 'find\s.*(-delete|-exec\s*(rm|shred))'; then
  echo '{"decision": "block", "reason": "Blocked: find -delete/-exec rm bypasses user confirmation. Use rm instead."}' >&2
  exit 2
fi

# xargs rm / shred（確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE 'xargs\s+(rm|shred)'; then
  echo '{"decision": "block", "reason": "Blocked: xargs rm/shred bypasses user confirmation. Use rm instead."}' >&2
  exit 2
fi

# perl/python ワンライナーによるファイル削除（確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE 'perl\s+-e\s.*unlink|python3?\s+-c\s.*os\.(remove|unlink)'; then
  echo '{"decision": "block", "reason": "Blocked: file deletion via scripting language bypasses user confirmation. Use rm instead."}' >&2
  exit 2
fi

# mv で /dev/null に移動（実質削除、確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE 'mv\s+.*\s+/dev/null'; then
  echo '{"decision": "block", "reason": "Blocked: mv to /dev/null bypasses user confirmation. Use rm instead."}' >&2
  exit 2
fi

# shred 単体（確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE '\bshred\s'; then
  echo '{"decision": "block", "reason": "Blocked: shred bypasses user confirmation. Use rm instead."}' >&2
  exit 2
fi

# Modification of settings files (パス付き・相対パス両方をカバー)
if echo "$COMMAND" | grep -qE '(>|>>|tee)\s*.*(settings\.json|\.claude\.json|\.mcp\.json)'; then
  echo '{"decision": "block", "reason": "Blocked: modification of Claude Code settings files"}' >&2
  exit 2
fi

# sed -i / jq による settings ファイル変更（リダイレクト以外のバイパス防止）
if echo "$COMMAND" | grep -qE '(sed\s+-i|jq\s+.*>)\s*.*(settings\.json|\.claude\.json|\.mcp\.json)'; then
  echo '{"decision": "block", "reason": "Blocked: in-place modification of Claude Code settings files"}' >&2
  exit 2
fi

# サンドボックス無効化の試行検出
if echo "$COMMAND" | grep -qiE 'sandbox.*enabled.*false|"enabled"\s*:\s*false.*sandbox|dangerouslyDisableSandbox'; then
  echo '{"decision": "block", "reason": "Blocked: attempt to disable sandbox"}' >&2
  exit 2
fi

# --- python / node 経由の egress 検出（情報提供レベル）---
# 主防御は init-firewall.sh の egress 許可リスト（24 ドメインのみ通信可）。
# このチェックは「気づき」を提供するもので、firewall を回避することは不可能。
# 開発で正当に使う場面（Anthropic API、PyPI アクセス等）が多いため警告のみが既定。
# 強制ブロックしたい場合は STRICT_EGRESS_BLOCK=true を設定する。
EGRESS_HIT=""
EGRESS_REASON=""

if echo "$COMMAND" | grep -qE '\b(python|python3)\s+-c\b.*\b(urllib|httplib|http\.client|requests|socket|aiohttp|urllib3|httpx)\b'; then
  EGRESS_HIT="true"
  EGRESS_REASON="Python ネットワークモジュール (urllib/http.client/requests/socket/aiohttp/urllib3/httpx) の直接実行を検出"
fi

if echo "$COMMAND" | grep -qE "\bnode\s+-[ep]\b.*(require\(['\"](https?|net|http2)['\"]\)|\bfetch\s*\()"; then
  EGRESS_HIT="true"
  EGRESS_REASON="Node 標準モジュール (http/https/net/http2/fetch) の直接実行を検出"
fi

if [ -n "$EGRESS_HIT" ]; then
  if [ "${STRICT_EGRESS_BLOCK:-false}" = "true" ]; then
    echo "{\"decision\": \"block\", \"reason\": \"Blocked (STRICT_EGRESS_BLOCK=true): ${EGRESS_REASON}. Set STRICT_EGRESS_BLOCK=false to allow with warning only.\"}" >&2
    exit 2
  else
    echo "[block-dangerous] WARN: ${EGRESS_REASON}. firewall が許可ドメインのみ通すので主防御は維持されますが、意図した処理か確認してください。STRICT_EGRESS_BLOCK=true でブロック動作に切替可能。" >&2
  fi
fi

# All checks passed
exit 0
