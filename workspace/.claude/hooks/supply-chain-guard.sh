#!/usr/bin/env bash
# supply-chain-guard.sh — PreToolUse Hook for package install commands
# Exit 0 = allow, Exit 2 = block
#
# 4 層チェック:
#   1. パッケージインストールコマンドの検出
#   2. typosquatting 検知（人気パッケージとの類似度）
#   3. 悪意パターン検出（危険なキーワード）
#   4. （将来）lockfile 存在確認、クールダウン設定確認
#
# 無効化: ENABLE_SUPPLY_CHAIN_GUARD=false

set -uo pipefail

# --- 無効化チェック ---
if [ "${ENABLE_SUPPLY_CHAIN_GUARD:-true}" = "false" ]; then
  exit 0
fi

# stdin から tool_input を読み取る
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# --- パッケージインストールコマンドの検出 ---
# npm install, npm i, npm add, pip install, uv add, uv pip install
PACKAGES=""
if echo "$COMMAND" | grep -qE '^\s*(npm)\s+(install|i|add)\s'; then
  PACKAGES=$(echo "$COMMAND" | sed -E 's/^\s*npm\s+(install|i|add)\s+//' | tr ' ' '\n' | grep -vE '^-' | grep -vE '^\s*$' || true)
elif echo "$COMMAND" | grep -qE '^\s*(pip)\s+install\s'; then
  PACKAGES=$(echo "$COMMAND" | sed -E 's/^\s*pip\s+install\s+//' | tr ' ' '\n' | grep -vE '^-' | grep -vE '^\s*$' || true)
elif echo "$COMMAND" | grep -qE '^\s*(uv)\s+add\s'; then
  PACKAGES=$(echo "$COMMAND" | sed -E 's/^\s*uv\s+add\s+//' | tr ' ' '\n' | grep -vE '^-' | grep -vE '^\s*$' || true)
elif echo "$COMMAND" | grep -qE '^\s*(uv)\s+pip\s+install\s'; then
  PACKAGES=$(echo "$COMMAND" | sed -E 's/^\s*uv\s+pip\s+install\s+//' | tr ' ' '\n' | grep -vE '^-' | grep -vE '^\s*$' || true)
else
  exit 0
fi

if [ -z "$PACKAGES" ]; then
  exit 0
fi

# --- 悪意パターン検出 ---
MALICIOUS_PATTERNS='hack|backdoor|keylog|reverse.shell|trojan|malware|exploit|rootkit|ransomware|spyware|phishing|stealer|rat-|cryptominer|botnet'

for pkg in $PACKAGES; do
  if echo "$pkg" | grep -qiE "$MALICIOUS_PATTERNS"; then
    echo "{\"decision\": \"block\", \"reason\": \"Blocked: suspicious package name '$pkg' matches malicious pattern\"}" >&2
    exit 2
  fi
done

# --- typosquatting 検出 ---
# python3 が利用可能な場合のみ実行
if command -v python3 >/dev/null 2>&1; then
  for pkg in $PACKAGES; do
    # スコープ付きパッケージ (@types/node 等) はスキップ
    if echo "$pkg" | grep -qE '^@'; then
      continue
    fi

    TYPO_RESULT=""
    TYPO_RESULT=$(python3 - "$pkg" << 'PYEOF'
import sys

POPULAR = [
    'express', 'react', 'react-dom', 'lodash', 'axios', 'chalk',
    'moment', 'debug', 'commander', 'inquirer', 'webpack', 'babel',
    'eslint', 'prettier', 'typescript', 'next', 'vue', 'angular',
    'jquery', 'underscore', 'async', 'bluebird', 'request', 'got',
    'node-fetch', 'cheerio', 'socket.io', 'mongoose', 'sequelize',
    'requests', 'flask', 'django', 'fastapi', 'numpy', 'pandas',
    'scipy', 'matplotlib', 'pillow', 'beautifulsoup4', 'scrapy',
    'celery', 'sqlalchemy', 'pytest', 'boto3', 'tensorflow',
    'torch', 'scikit-learn', 'pydantic', 'httpx', 'uvicorn',
]

def levenshtein(s1, s2):
    if len(s1) < len(s2):
        return levenshtein(s2, s1)
    if len(s2) == 0:
        return len(s1)
    prev = range(len(s2) + 1)
    for i, c1 in enumerate(s1):
        curr = [i + 1]
        for j, c2 in enumerate(s2):
            curr.append(min(curr[j] + 1, prev[j + 1] + 1, prev[j] + (c1 != c2)))
        prev = curr
    return prev[-1]

pkg = sys.argv[1].lower()
if pkg in POPULAR:
    sys.exit(0)
for popular in POPULAR:
    dist = levenshtein(pkg, popular)
    if dist == 0:
        sys.exit(0)
    threshold = 1 if len(popular) <= 4 else 2
    if 0 < dist <= threshold:
        print(popular)
        sys.exit(1)
sys.exit(0)
PYEOF
) || true

    if [ -n "$TYPO_RESULT" ]; then
      echo "{\"decision\": \"block\", \"reason\": \"Blocked: '$pkg' looks like a typosquatting of '$TYPO_RESULT'. Did you mean '$TYPO_RESULT'?\"}" >&2
      exit 2
    fi
  done
fi

# All checks passed
exit 0
