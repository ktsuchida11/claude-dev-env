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

# rm -rf with dangerous targets
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+|--force\s+)*(\/|~|\$HOME|\.\.)'; then
  echo '{"decision": "block", "reason": "Blocked: rm -rf with dangerous target path"}' >&2
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

# chmod 777 (overly permissive)
if echo "$COMMAND" | grep -qE 'chmod\s+777'; then
  echo '{"decision": "block", "reason": "Blocked: chmod 777 is not allowed"}' >&2
  exit 2
fi

# Modification of settings files
if echo "$COMMAND" | grep -qE '(>|>>|tee)\s*.*/(settings\.json|\.claude\.json|\.mcp\.json)'; then
  echo '{"decision": "block", "reason": "Blocked: modification of Claude Code settings files"}' >&2
  exit 2
fi

# All checks passed
exit 0
