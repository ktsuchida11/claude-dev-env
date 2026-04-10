#!/usr/bin/env bash
# supply-chain-guard.sh — PreToolUse Hook for package install commands
# Exit 0 = allow, Exit 2 = block
#
# Layer 2: パッケージインストール前のサプライチェーン攻撃対策
# - Lockfile の存在チェック
# - Typosquatting 検知（人気パッケージとの類似度チェック）
# - 既知の悪意あるパッケージ名のブロック
#
# 無効化: ENABLE_SUPPLY_CHAIN_GUARD=false

set -euo pipefail

# ON/OFF 制御
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

# npm install / npm add の検出
NPM_INSTALL=""
if echo "$COMMAND" | grep -qE '^\s*npm\s+(install|i|add)\b'; then
  NPM_INSTALL="true"
fi

# pip install / uv pip install / uv add の検出
PIP_INSTALL=""
if echo "$COMMAND" | grep -qE '^\s*(pip|pip3)\s+install\b'; then
  PIP_INSTALL="true"
fi
if echo "$COMMAND" | grep -qE '^\s*uv\s+(pip\s+install|add)\b'; then
  PIP_INSTALL="true"
fi

# mvn / gradle の検出（依存関係追加はビルドファイル編集で行うため、ここではスキップ）
# Maven/Gradle はレジストリ固定（.mvn-settings.xml）で対策

# パッケージインストールでなければスルー
if [ -z "$NPM_INSTALL" ] && [ -z "$PIP_INSTALL" ]; then
  exit 0
fi

# === チェック開始 ===

HEADER_SHOWN=""
show_header() {
  if [ -z "$HEADER_SHOWN" ]; then
    echo "" >&2
    echo "Supply Chain Guard - Pre-Install Check" >&2
    echo "==========================================" >&2
    HEADER_SHOWN="true"
  fi
}

BLOCK=""

# --- 1. Lockfile チェック ---

check_lockfile() {
  local cmd_dir
  # コマンドに cd が含まれる場合はそのディレクトリを使う
  cmd_dir=$(echo "$COMMAND" | sed -nE 's/.*cd[[:space:]]+([^[:space:];&]+).*/\1/p' | head -1 || true)

  if [ -n "$NPM_INSTALL" ]; then
    # npm install <package> の場合はlockfileチェック不要（追加なので）
    # npm install（引数なし）の場合のみチェック
    if echo "$COMMAND" | grep -qE '^\s*npm\s+(install|i)\s*$'; then
      local search_dir="${cmd_dir:-.}"
      if [ ! -f "$search_dir/package-lock.json" ] && [ ! -f "$search_dir/npm-shrinkwrap.json" ]; then
        show_header
        echo "  [WARN] Lockfile: package-lock.json が見つかりません" >&2
        echo "         npm install は lockfile なしだと依存解決が不安定になります" >&2
        echo "         先に npm install --package-lock-only で lockfile を生成してください" >&2
      else
        show_header
        echo "  [OK] Lockfile: package-lock.json found" >&2
      fi
    fi
  fi

  if [ -n "$PIP_INSTALL" ]; then
    # uv add / pip install -r requirements.txt の場合
    if echo "$COMMAND" | grep -qE '(-r|--requirement)\s'; then
      local search_dir="${cmd_dir:-.}"
      if [ ! -f "$search_dir/uv.lock" ] && [ ! -f "$search_dir/requirements.txt" ]; then
        show_header
        echo "  [WARN] Lockfile: uv.lock / requirements.txt が見つかりません" >&2
      fi
    fi
  fi
}

# --- 2. Typosquatting 検知 ---

# npm の人気パッケージリスト（typosquatting のターゲットになりやすい）
NPM_POPULAR=(
  "express" "react" "react-dom" "next" "vue" "angular" "lodash" "axios"
  "moment" "chalk" "commander" "debug" "dotenv" "webpack" "babel"
  "typescript" "eslint" "prettier" "jest" "mocha" "chai" "sinon"
  "mongoose" "sequelize" "prisma" "socket.io" "cors" "helmet"
  "jsonwebtoken" "bcrypt" "uuid" "yargs" "inquirer" "ora" "glob"
  "rimraf" "mkdirp" "fs-extra" "path" "request" "node-fetch" "got"
  "cheerio" "puppeteer" "playwright" "sharp" "multer" "formidable"
  "nodemon" "pm2" "concurrently" "cross-env" "dotenv-cli"
  "tailwindcss" "postcss" "autoprefixer" "sass" "less"
  "three" "d3" "chart.js" "echarts"
  "aws-sdk" "firebase" "stripe" "twilio" "nodemailer"
)

# PyPI の人気パッケージリスト
PIP_POPULAR=(
  "requests" "flask" "django" "fastapi" "numpy" "pandas" "scipy"
  "matplotlib" "pillow" "beautifulsoup4" "scrapy" "selenium"
  "sqlalchemy" "psycopg2" "pymongo" "redis" "celery" "boto3"
  "pytest" "unittest" "coverage" "tox" "black" "ruff" "mypy"
  "pydantic" "httpx" "aiohttp" "uvicorn" "gunicorn" "starlette"
  "click" "typer" "rich" "colorama" "tqdm" "loguru"
  "cryptography" "pyjwt" "bcrypt" "passlib" "python-dotenv"
  "jinja2" "pyyaml" "toml" "orjson" "ujson"
  "tensorflow" "pytorch" "torch" "transformers" "langchain"
  "openai" "anthropic" "tiktoken" "langfuse"
)

# Typosquatting 一括チェック（Python で全パッケージを一度に比較）
# 出力形式: 1行ごとに "pkg_name\tresult\tsimilar_to"
#   result = "exact" | "suspect" | "ok"
batch_typosquatting_check() {
  local packages_csv="$1"  # カンマ区切りのパッケージ名
  local popular_csv="$2"   # カンマ区切りの人気パッケージ名

  python3 -c "
import sys

def levenshtein(s1, s2):
    if abs(len(s1) - len(s2)) > 3:
        return 99
    m, n = len(s1), len(s2)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev = dp[0]
        dp[0] = i
        for j in range(1, n + 1):
            temp = dp[j]
            dp[j] = min(dp[j] + 1, dp[j-1] + 1, prev + (0 if s1[i-1] == s2[j-1] else 1))
            prev = temp
    return dp[n]

packages = [p for p in '$packages_csv'.split(',') if p]
popular = [p for p in '$popular_csv'.split(',') if p]
popular_set = set(popular)

for pkg in packages:
    if pkg in popular_set:
        print(f'{pkg}\texact\t')
        continue
    found = False
    for pop in popular:
        d = levenshtein(pkg, pop)
        if 0 < d <= 2:
            print(f'{pkg}\tsuspect\t{pop}')
            found = True
            break
    if not found:
        print(f'{pkg}\tok\t')
" 2>/dev/null
}

check_typosquatting() {
  local packages=()
  local popular_list=()

  if [ -n "$NPM_INSTALL" ]; then
    # npm install <pkg1> <pkg2> ... からパッケージ名を抽出
    # フラグ (--save-dev, -D 等) とスコープ付きパッケージ (@scope/name) に対応
    packages=($(echo "$COMMAND" | sed -nE 's/.*npm[[:space:]]+(install|i|add)[[:space:]]+//p' | tr ' ' '\n' | grep -vE '^-' | sed 's/@[0-9^~><=].*$//' || true))
    popular_list=("${NPM_POPULAR[@]}")
  elif [ -n "$PIP_INSTALL" ]; then
    # pip install <pkg1> <pkg2> ... からパッケージ名を抽出
    packages=($(echo "$COMMAND" | sed -nE 's/.*(install|add)[[:space:]]+//p' | tr ' ' '\n' | grep -vE '^-' | sed 's/[><=!].*$//' | sed 's/\[.*\]$//' || true))
    popular_list=("${PIP_POPULAR[@]}")
  fi

  [ ${#packages[@]} -eq 0 ] && return

  # パッケージ名を正規化（スコープ除去・小文字化）
  local normalized=()
  local original=()
  for pkg in "${packages[@]}"; do
    local pkg_name="${pkg##*/}"
    pkg_name=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]')
    [ -z "$pkg_name" ] && continue
    normalized+=("$pkg_name")
    original+=("$pkg")
  done

  [ ${#normalized[@]} -eq 0 ] && return

  # カンマ区切りに変換
  local packages_csv
  packages_csv=$(IFS=,; echo "${normalized[*]}")
  local popular_csv
  popular_csv=$(IFS=,; echo "${popular_list[*]}")

  # Python 1回で全パッケージを一括チェック
  local results
  results=$(batch_typosquatting_check "$packages_csv" "$popular_csv")

  local idx=0
  while IFS=$'\t' read -r pkg_name result similar_to; do
    local orig_pkg="${original[$idx]}"
    idx=$((idx + 1))

    case "$result" in
      exact)
        show_header
        echo "  [OK] Package: $orig_pkg — verified (known package)" >&2
        ;;
      suspect)
        show_header
        echo "  [BLOCK] Package: $orig_pkg — typosquatting の疑い (類似: $similar_to)" >&2
        echo "          パッケージ名を確認してください。正しい場合は直接 npm/pip コマンドで実行してください" >&2
        BLOCK="true"
        ;;
    esac
  done <<< "$results"
}

# --- 3. 既知の悪意あるパッケージパターン ---

check_malicious_patterns() {
  local packages_str=""

  if [ -n "$NPM_INSTALL" ]; then
    packages_str=$(echo "$COMMAND" | sed 's/.*\(install\|add\)\s\+//')
  elif [ -n "$PIP_INSTALL" ]; then
    packages_str=$(echo "$COMMAND" | sed 's/.*\(install\|add\)\s\+//')
  fi

  # 既知の悪意あるパッケージ名パターン
  # - ハイフンとアンダースコアの混同 (requests vs request_s)
  # - "python-" プレフィックス付きの偽パッケージ
  # - "-js" サフィックス付きの偽パッケージ
  # - "node-" プレフィックス付きの公式でないパッケージ

  # パッケージ名に疑わしい文字列が含まれる場合の警告
  if echo "$packages_str" | grep -qiE '(hack|steal|exfil|reverse.?shell|backdoor|keylog|trojan)'; then
    show_header
    echo "  [BLOCK] 疑わしいパッケージ名パターンを検出しました" >&2
    echo "          パッケージ名を確認してください" >&2
    BLOCK="true"
  fi
}

# --- 4. クールダウン確認 ---
# npm: min-release-age=7 (.npmrc) — ネイティブサポート（npm v11.10.0+）
# uv:  exclude-newer = "<日時>" (uv.toml) — RFC 3339 絶対日時、cooldown-update.sh で更新
# pip: uploaded-prior-to (pip.conf) — 絶対日付のため定期更新が必要
#
# このセクションはネイティブ設定の有効性を確認・補完する

COOLDOWN_DAYS="${SUPPLY_CHAIN_COOLDOWN_DAYS:-7}"

verify_cooldown() {
  if [ -n "$NPM_INSTALL" ]; then
    # .npmrc に min-release-age が設定されているか確認
    local npmrc_found=""
    for f in ./.npmrc ../../../.npmrc /workspace/.npmrc; do
      if [ -f "$f" ] && grep -q 'min-release-age' "$f" 2>/dev/null; then
        npmrc_found="true"
        break
      fi
    done
    if [ -n "$npmrc_found" ]; then
      show_header
      echo "  [OK] Cooldown: min-release-age=${COOLDOWN_DAYS} (.npmrc)" >&2
    else
      show_header
      echo "  [WARN] Cooldown: .npmrc に min-release-age が未設定です" >&2
      echo "         npm v11.10.0+ では min-release-age=7 を推奨します" >&2
    fi
    # --min-release-age=0 でバイパスしようとしている場合は警告
    if echo "$COMMAND" | grep -qE '\-\-min-release-age\s*=\s*0'; then
      show_header
      echo "  [WARN] Cooldown: min-release-age=0 でクールダウンがバイパスされます" >&2
      echo "         緊急のセキュリティパッチ適用時のみ使用してください" >&2
    fi
  fi

  if [ -n "$PIP_INSTALL" ]; then
    if echo "$COMMAND" | grep -qE '^\s*uv\s+(pip\s+install|add)\b'; then
      # uv: uv.toml の exclude-newer を確認
      local uvtoml_found=""
      for f in ./uv.toml ../../../uv.toml /workspace/uv.toml; do
        if [ -f "$f" ] && grep -q 'exclude-newer' "$f" 2>/dev/null; then
          uvtoml_found="true"
          break
        fi
      done
      if [ -n "$uvtoml_found" ]; then
        show_header
        echo "  [OK] Cooldown: exclude-newer=P${COOLDOWN_DAYS}D (uv.toml)" >&2
      else
        show_header
        echo "  [WARN] Cooldown: uv.toml に exclude-newer が未設定です" >&2
        echo "         exclude-newer = \"<7日前の日時>\" を推奨します（cooldown-update.sh で更新）" >&2
      fi
      # --exclude-newer で現在時刻（バイパス）を指定している場合は警告
      if echo "$COMMAND" | grep -qE '\-\-exclude-newer\s+.*\$\(date'; then
        show_header
        echo "  [WARN] Cooldown: exclude-newer に現在時刻が指定されています（バイパス）" >&2
      fi

    elif echo "$COMMAND" | grep -qE '^\s*(pip|pip3)\s+install\b'; then
      # pip: pip.conf の uploaded-prior-to を確認
      local pipconf="/workspace/.pip.conf"
      if [ -f "$pipconf" ] && grep -q 'uploaded-prior-to' "$pipconf" 2>/dev/null; then
        local pip_date
        pip_date=$(grep 'uploaded-prior-to' "$pipconf" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
        show_header
        echo "  [OK] Cooldown: uploaded-prior-to=$pip_date (pip.conf)" >&2
        # 日付が古すぎないか警告（14日以上前）
        local pip_epoch today_epoch
        pip_epoch=$(date -d "$pip_date" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$pip_date" +%s 2>/dev/null || echo "0")
        today_epoch=$(date +%s)
        if [ "$pip_epoch" != "0" ]; then
          local age_days=$(( (today_epoch - pip_epoch) / 86400 ))
          if [ "$age_days" -gt 14 ]; then
            echo "  [WARN] pip.conf の uploaded-prior-to が ${age_days} 日前です" >&2
            echo "         新しいパッケージをインストールできない可能性があります" >&2
            echo "         値を更新してください（推奨: 7日前の日付）" >&2
          fi
        fi
      else
        show_header
        echo "  [WARN] Cooldown: pip.conf に uploaded-prior-to が未設定です" >&2
        echo "         代わりに uv の使用を推奨します（相対日付サポート）" >&2
      fi
    fi
  fi
}

# --- チェック実行 ---

check_lockfile
check_typosquatting
check_malicious_patterns
verify_cooldown

# ヘッダが表示されていない = インストールだがチェック対象なし（フラグのみ等）
if [ -n "$HEADER_SHOWN" ]; then
  echo "==========================================" >&2
fi

if [ -n "$BLOCK" ]; then
  echo '{"decision": "block", "reason": "Supply Chain Guard: suspicious package detected"}' >&2
  exit 2
fi

exit 0
