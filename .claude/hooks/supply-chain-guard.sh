#!/usr/bin/env bash
# supply-chain-guard.sh — PreToolUse Hook for package install commands
# Exit 0 = allow, Exit 2 = block
#
# 4 層チェック:
#   1. lockfile / hash mode 確認（再現性確保、本ガードの早期実行）
#   2. パッケージインストールコマンドの検出
#   3. 悪意パターン検出（危険なキーワード）
#   4. typosquatting 検知（人気パッケージとの類似度）
#
# 無効化: ENABLE_SUPPLY_CHAIN_GUARD=false
# lockfile チェックのみ無効化: SKIP_LOCKFILE_CHECK=true

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


# === lockfile / hash mode チェック ===
# transitive 依存の再現性が無いと、毎回最新版が取得され攻撃の入り口となる。
# パッケージ名抽出より前に走らせるのは、`npm install`（引数なし）や `uv sync`
# のように specific package 引数を持たないコマンドも対象に含めるため。
if [ "${SKIP_LOCKFILE_CHECK:-false}" != "true" ]; then
  CHECK_DIR="${PWD:-/workspace}"

  block_lockfile() {
    local mgr="$1" required="$2" hint="$3"
    echo "{\"decision\": \"block\", \"reason\": \"Blocked: ${mgr} requires ${required} for reproducible install. ${hint}\"}" >&2
    exit 2
  }

  warn_hash_mode() {
    local req_file="$1"
    if [ -f "$req_file" ]; then
      if ! grep -qE '\-\-require-hashes|\-\-hash=' "$req_file"; then
        echo "[supply-chain-guard] WARN: ${req_file} has no --require-hashes / --hash= entries. Hash pinning is recommended for reproducibility." >&2
      fi
    fi
  }

  # npm: install / i / add は lockfile 必須、ci は素通し
  if echo "$COMMAND" | grep -qE '^\s*npm\s+ci(\b|$)'; then
    : # npm ci 自体が lockfile 必須なので OK
  elif echo "$COMMAND" | grep -qE '^\s*npm\s+(install|i|add)(\b|$)'; then
    if [ ! -f "$CHECK_DIR/package-lock.json" ] && [ ! -f "$CHECK_DIR/npm-shrinkwrap.json" ]; then
      block_lockfile "npm" "package-lock.json" \
        "Run 'npm install --package-lock-only' to bootstrap, or use 'npm ci' if a lockfile exists."
    fi
  fi

  # uv: add / sync は uv.lock 必須
  if echo "$COMMAND" | grep -qE '^\s*uv\s+(add|sync)(\b|$)'; then
    if [ ! -f "$CHECK_DIR/uv.lock" ]; then
      block_lockfile "uv" "uv.lock" \
        "Run 'uv lock' to create the lockfile first."
    fi
  fi

  # uv pip install: -r requirements は hash mode 警告、単体パッケージは uv.lock 必須
  if echo "$COMMAND" | grep -qE '^\s*uv\s+pip\s+install(\b|$)'; then
    REQ_FILE=$(echo "$COMMAND" | grep -oE '\-r\s+\S+' | head -1 | awk '{print $2}')
    if [ -n "$REQ_FILE" ]; then
      warn_hash_mode "$REQ_FILE"
    else
      if [ ! -f "$CHECK_DIR/uv.lock" ]; then
        block_lockfile "uv pip install" "uv.lock" \
          "Use 'uv add <pkg>' inside a uv-managed project, or pass '-r requirements.txt' with --require-hashes."
      fi
    fi
  fi

  # pip install: -r requirements の場合のみ hash mode 警告（単体パッケージは lockfile 概念なし）
  if echo "$COMMAND" | grep -qE '^\s*pip3?\s+install(\b|$)'; then
    REQ_FILE=$(echo "$COMMAND" | grep -oE '\-r\s+\S+' | head -1 | awk '{print $2}')
    if [ -n "$REQ_FILE" ]; then
      warn_hash_mode "$REQ_FILE"
    fi
  fi
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
elif echo "$COMMAND" | grep -qE '^\s*npx(\s|$)'; then
  # npx は登録パッケージを 1 行で実行できるためサプライチェーン攻撃の起点になりうる。
  # 実行対象パッケージ名を抽出して typosquatting / 悪意パターン検査に通す。
  # 対応形式: npx <pkg>, npx -y <pkg>, npx -p <pkg> <bin>, npx --package <pkg>, npx --package=<pkg>
  PACKAGES=$(python3 - "$COMMAND" <<'PYEOF'
import shlex, sys
try:
    toks = shlex.split(sys.argv[1])
except ValueError:
    sys.exit(0)
if not toks or toks[0] != 'npx':
    sys.exit(0)
out = None
i = 1
while i < len(toks):
    t = toks[i]
    if t in ('-y', '--yes', '--no'):
        i += 1
        continue
    if t in ('-p', '--package'):
        if i + 1 < len(toks):
            out = toks[i + 1]
        break
    if t.startswith('--package='):
        out = t.split('=', 1)[1]
        break
    if t == '--':
        if i + 1 < len(toks):
            out = toks[i + 1]
        break
    if t.startswith('-'):
        i += 1
        continue
    out = t
    break
if not out:
    sys.exit(0)
# strip @version: name@1.2.3 -> name; @scope/name@1.2.3 -> @scope/name
if out.startswith('@'):
    rest = out[1:]
    if '@' in rest:
        scope_name, _ = rest.rsplit('@', 1)
        print('@' + scope_name)
    else:
        print(out)
elif '@' in out:
    print(out.rsplit('@', 1)[0])
else:
    print(out)
PYEOF
)
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
