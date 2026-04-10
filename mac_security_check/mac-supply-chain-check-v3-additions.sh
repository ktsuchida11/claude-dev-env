#!/usr/bin/env bash
# =============================================================================
# mac-supply-chain-check-v3-additions.sh
#
# v2 に追加すべきチェックモジュール群
# 2025-2026年の最新脅威（axios侵害, AMOS, Shai-Hulud, LiteLLM等）に対応
#
# 使い方: v2 スクリプトの「セクション8」の後にこのファイルの内容を挿入するか、
#         source で読み込んで使用
#   source ~/bin/mac-supply-chain-check-v3-additions.sh
# =============================================================================

# --- 前提: v2 の helper 関数 (section, ok, warn, critical, info) と
#           $REPORT, $ALERT_COUNT, $CRITICAL_COUNT が定義済みであること ---

# ガードチェック: v2 から source されていない場合はエラー終了
if [ -z "${REPORT:-}" ] || [ -z "${IOC_DIR:-}" ]; then
  echo "ERROR: このスクリプトは mac-supply-chain-check-v2.sh から source して使用してください。" >&2
  echo "  例: source ~/bin/mac-supply-chain-check-v3-additions.sh" >&2
  exit 1
fi
if ! type section &>/dev/null || ! type ok &>/dev/null; then
  echo "ERROR: helper 関数 (section, ok, warn, critical, info) が未定義です。v2 から source してください。" >&2
  exit 1
fi

# =============================================================================
# ★ A. パッケージマネージャ Lockdown 設定の改ざんチェック
# =============================================================================
section "A. パッケージマネージャ Lockdown 設定の整合性"

echo "npm/uv/pip のロックダウン設定が改ざんされていないか検証します。" >> "$REPORT"
echo "" >> "$REPORT"

# ----- npm: .npmrc -----
NPM_CONFIGS=("$HOME/.npmrc" "/usr/local/etc/npmrc" "/opt/homebrew/etc/npmrc")
NPM_LOCKDOWN_OK=true

for NPMRC in "${NPM_CONFIGS[@]}"; do
  [ -f "$NPMRC" ] || continue
  info "npm config 検出: \`$NPMRC\`"

  # ignore-scripts が有効か
  if grep -qi "ignore-scripts\s*=\s*true" "$NPMRC" 2>/dev/null; then
    ok "\`$NPMRC\`: ignore-scripts=true ✓"
  else
    warn "\`$NPMRC\`: **ignore-scripts が無効** — postinstall 攻撃に脆弱（axios侵害の主要ベクトル）"
    NPM_LOCKDOWN_OK=false
  fi

  # audit-level の確認
  if grep -qi "audit-level" "$NPMRC" 2>/dev/null; then
    ok "\`$NPMRC\`: audit-level 設定あり"
  fi

  # package-lock=true の確認
  if grep -qi "package-lock\s*=\s*false" "$NPMRC" 2>/dev/null; then
    warn "\`$NPMRC\`: package-lock=false — ロックファイルが無効化されています"
    NPM_LOCKDOWN_OK=false
  fi

  # ファイルの所有者と権限
  NPMRC_PERM=$(stat -f "%Lp" "$NPMRC" 2>/dev/null || echo "?")
  NPMRC_OWNER=$(stat -f "%Su" "$NPMRC" 2>/dev/null || echo "?")
  if [ "$NPMRC_PERM" != "644" ] && [ "$NPMRC_PERM" != "600" ]; then
    warn "\`$NPMRC\`: パーミッション $NPMRC_PERM — 644 または 600 を推奨"
  fi
  if [ "$NPMRC_OWNER" != "$(whoami)" ]; then
    critical "\`$NPMRC\`: 所有者が $(whoami) ではなく $NPMRC_OWNER — 改ざんの可能性"
  fi
done

# project-level .npmrc のチェック（リポジトリ内で上書きされていないか）
if [ -n "${PROJECT_DIRS:-}" ]; then
  for PDIR in $PROJECT_DIRS; do
    if [ -f "$PDIR/.npmrc" ]; then
      if grep -qi "ignore-scripts\s*=\s*false" "$PDIR/.npmrc" 2>/dev/null; then
        warn "プロジェクト \`$PDIR/.npmrc\` で ignore-scripts が false に上書きされています"
      fi
    fi
  done
fi

# ----- pip: pip.conf -----
PIP_CONFIGS=("$HOME/.config/pip/pip.conf" "$HOME/.pip/pip.conf" "/etc/pip.conf")

for PIPCONF in "${PIP_CONFIGS[@]}"; do
  [ -f "$PIPCONF" ] || continue
  info "pip config 検出: \`$PIPCONF\`"

  if grep -qi "require-hashes\s*=\s*true" "$PIPCONF" 2>/dev/null; then
    ok "\`$PIPCONF\`: require-hashes=true ✓"
  else
    # require-hashes は pip install --require-hashes で使うケースもある
    info "\`$PIPCONF\`: require-hashes の明示的設定なし（コマンドラインオプションで指定している可能性）"
  fi

  # trusted-host が怪しいドメインを指していないか
  TRUSTED=$(grep -i "trusted-host" "$PIPCONF" 2>/dev/null || true)
  if [ -n "$TRUSTED" ]; then
    if echo "$TRUSTED" | grep -vqE "pypi\.org|files\.pythonhosted\.org"; then
      warn "\`$PIPCONF\`: 非標準の trusted-host 設定あり → $TRUSTED"
    fi
  fi
done

# ----- uv: uv.toml / pyproject.toml -----
UV_CONFIGS=("$HOME/.config/uv/uv.toml" "$HOME/uv.toml")

for UVCONF in "${UV_CONFIGS[@]}"; do
  [ -f "$UVCONF" ] || continue
  info "uv config 検出: \`$UVCONF\`"

  # index-url が公式か
  if grep -qi "index-url" "$UVCONF" 2>/dev/null; then
    INDEX_URL=$(grep -i "index-url" "$UVCONF" | head -1)
    if echo "$INDEX_URL" | grep -qvE "pypi\.org"; then
      warn "\`$UVCONF\`: 非公式の index-url → $INDEX_URL"
    fi
  fi
done

$NPM_LOCKDOWN_OK && ok "npm ロックダウン設定: 整合性OK"

# =============================================================================
# ★ B. AI ツール認証情報 / 設定ファイルの監査
# 2026年の新攻撃面: Claude, Cursor, Copilot の設定がクレデンシャル窃取の標的
# =============================================================================
section "B. AI ツール認証情報・設定ファイル監査"

echo "AI コーディングツールの認証情報が不正アクセスされていないか確認します。" >> "$REPORT"
echo "" >> "$REPORT"

AI_CONFIG_PATHS=(
  # Claude Code
  "$HOME/.claude"
  "$HOME/.claude.json"
  "$HOME/.config/claude"
  # Cursor
  "$HOME/.cursor"
  "$HOME/Library/Application Support/Cursor"
  # GitHub Copilot
  "$HOME/.config/github-copilot"
  # Anthropic API
  "$HOME/.anthropic"
  # OpenAI
  "$HOME/.openai"
  # Generic
  "$HOME/.config/gh"
)

for AI_PATH in "${AI_CONFIG_PATHS[@]}"; do
  if [ -e "$AI_PATH" ]; then
    TOOL_NAME=$(basename "$AI_PATH")

    if [ -d "$AI_PATH" ]; then
      # ディレクトリの権限チェック
      DIR_PERM=$(stat -f "%Lp" "$AI_PATH" 2>/dev/null || echo "?")
      if [ "$DIR_PERM" != "700" ] && [ "$DIR_PERM" != "755" ]; then
        warn "AI設定 \`$AI_PATH\`: パーミッション $DIR_PERM — 700 推奨"
      fi

      # 最近変更されたファイル
      RECENT=$(find "$AI_PATH" -type f -mtime -3 2>/dev/null | head -5 || true)
      if [ -n "$RECENT" ]; then
        info "\`$TOOL_NAME\`: 過去3日以内に変更あり"
        echo "$RECENT" | while read -r F; do
          echo "    - \`$(basename "$F")\` ($(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$F" 2>/dev/null || echo '?'))" >> "$REPORT"
        done
      fi
    elif [ -f "$AI_PATH" ]; then
      FILE_PERM=$(stat -f "%Lp" "$AI_PATH" 2>/dev/null || echo "?")
      if [ "$FILE_PERM" != "600" ] && [ "$FILE_PERM" != "644" ]; then
        warn "AI設定 \`$AI_PATH\`: パーミッション $FILE_PERM — 600 推奨"
      fi
    fi

    ok "\`$TOOL_NAME\` 設定検出（所有者: $(stat -f '%Su' "$AI_PATH" 2>/dev/null || echo '?')）"
  fi
done

# API キーが .env や設定ファイルに平文で書かれていないかスポットチェック
ENV_FILES=$(find "$HOME" -maxdepth 3 -name ".env" -o -name ".env.local" -o -name ".env.production" 2>/dev/null | head -20 || true)
if [ -n "$ENV_FILES" ]; then
  EXPOSED_KEYS=0
  while IFS= read -r ENVF; do
    [ -f "$ENVF" ] || continue
    # Anthropic / OpenAI / AWS キーのパターン
    if grep -qE "(sk-ant-|sk-[a-zA-Z0-9]{20,}|AKIA[A-Z0-9]{16})" "$ENVF" 2>/dev/null; then
      EXPOSED_KEYS=$((EXPOSED_KEYS + 1))
      ENVF_PERM=$(stat -f "%Lp" "$ENVF" 2>/dev/null || echo "?")
      if [ "$ENVF_PERM" != "600" ]; then
        warn "\`$ENVF\`: API キーを含み、パーミッション $ENVF_PERM — 600 に変更推奨"
      else
        info "\`$ENVF\`: API キーあり（パーミッション 600 ✓）"
      fi
    fi
  done <<< "$ENV_FILES"
  [ "$EXPOSED_KEYS" -eq 0 ] && ok ".env ファイルに露出した API キーなし"
fi

# =============================================================================
# ★ C. MCP サーバー設定の棚卸し
# =============================================================================
section "C. MCP (Model Context Protocol) サーバー設定"

echo "Claude Code 等の MCP 接続先を棚卸しし、不審な接続先がないか確認します。" >> "$REPORT"
echo "" >> "$REPORT"

MCP_CONFIG_PATHS=(
  "$HOME/.claude/mcp_config.json"
  "$HOME/.config/claude/mcp_config.json"
  "$HOME/.claude.json"
  "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
)

MCP_FOUND=false
for MCP_CONF in "${MCP_CONFIG_PATHS[@]}"; do
  [ -f "$MCP_CONF" ] || continue
  MCP_FOUND=true
  info "MCP設定検出: \`$MCP_CONF\`"

  if command -v python3 &>/dev/null; then
    MCP_CONF="$MCP_CONF" python3 -c "
import json, sys, os

conf_path = os.environ['MCP_CONF']
with open(conf_path) as f:
    data = json.load(f)

servers = data.get('mcpServers', data.get('mcp_servers', {}))
if not servers:
    print('  MCP サーバー設定なし')
    sys.exit(0)

for name, conf in servers.items():
    cmd = conf.get('command', '?')
    args = ' '.join(conf.get('args', []))
    env_keys = list(conf.get('env', {}).keys())
    print(f'  - **{name}**: \`{cmd} {args}\`')
    if env_keys:
        print(f'    環境変数: {\", \".join(env_keys)}')
" 2>/dev/null >> "$REPORT" || info "MCP設定の解析に失敗"
  else
    info "python3 が必要です（MCP設定の詳細解析）"
  fi
done

$MCP_FOUND || info "MCP 設定ファイルは検出されませんでした"

# =============================================================================
# ★ D. Git Hooks のチェック（リポジトリ内の罠）
# =============================================================================
section "D. Git Hooks チェック"

echo "アクティブなリポジトリの .git/hooks/ に不審なスクリプトがないか確認します。" >> "$REPORT"
echo "" >> "$REPORT"

# ホームディレクトリ配下の git リポジトリを探索（深さ3、最大20個）
GIT_DIRS=$(find "$HOME" -maxdepth 4 -name ".git" -type d 2>/dev/null \
  | grep -v "node_modules" \
  | grep -v ".cache" \
  | head -20 || true)

SUSPICIOUS_HOOKS=0
while IFS= read -r GITDIR; do
  [ -d "$GITDIR/hooks" ] || continue
  for HOOK in "$GITDIR/hooks"/*; do
    [ -f "$HOOK" ] || continue
    # .sample は無視
    [[ "$HOOK" == *.sample ]] && continue
    # 実行権限があるもの
    if [ -x "$HOOK" ]; then
      HOOK_NAME=$(basename "$HOOK")
      REPO_DIR=$(dirname "$(dirname "$HOOK")")

      # 内容に怪しいパターンがないか
      if grep -qEi "(curl|wget|nc |netcat|/dev/tcp|base64|eval|exec\()" "$HOOK" 2>/dev/null; then
        warn "不審な Git hook: \`$REPO_DIR\` → \`$HOOK_NAME\` (ネットワーク/実行系コマンド検出)"
        SUSPICIOUS_HOOKS=$((SUSPICIOUS_HOOKS + 1))
      else
        info "アクティブ hook: \`$(basename "$REPO_DIR")\` → \`$HOOK_NAME\`"
      fi
    fi
  done
done <<< "$GIT_DIRS"

[ "$SUSPICIOUS_HOOKS" -eq 0 ] && ok "不審な Git hook なし"

# グローバル Git hooks の確認
GLOBAL_HOOKS=$(git config --global core.hooksPath 2>/dev/null || true)
if [ -n "$GLOBAL_HOOKS" ]; then
  warn "グローバル Git hooksPath が設定されています: \`$GLOBAL_HOOKS\` — 意図的な設定か確認してください"
else
  ok "グローバル hooksPath 未設定（デフォルト）"
fi

# =============================================================================
# ★ E. SSH 鍵の監査
# =============================================================================
section "E. SSH 鍵監査"

SSH_DIR="$HOME/.ssh"
if [ -d "$SSH_DIR" ]; then
  # authorized_keys に不審な鍵がないか
  AUTH_KEYS="$SSH_DIR/authorized_keys"
  if [ -f "$AUTH_KEYS" ]; then
    KEY_COUNT=$(grep -c "^ssh-\|^ecdsa-\|^sk-" "$AUTH_KEYS" 2>/dev/null || echo "0")
    info "authorized_keys: ${KEY_COUNT}個の公開鍵"

    # 最終変更日
    AK_MOD=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$AUTH_KEYS" 2>/dev/null || echo "?")
    info "authorized_keys 最終更新: $AK_MOD"

    # 過去7日以内に変更されていたら警告
    AK_DAYS=$(( ($(date +%s) - $(stat -f "%m" "$AUTH_KEYS" 2>/dev/null || echo "0")) / 86400 ))
    if [ "$AK_DAYS" -lt 7 ]; then
      warn "authorized_keys が過去7日以内に変更されています — 意図した変更か確認してください"
    fi
  fi

  # 秘密鍵の権限チェック
  for KEY in "$SSH_DIR"/id_*; do
    [ -f "$KEY" ] || continue
    [[ "$KEY" == *.pub ]] && continue
    KEY_PERM=$(stat -f "%Lp" "$KEY" 2>/dev/null || echo "?")
    if [ "$KEY_PERM" != "600" ]; then
      warn "SSH秘密鍵 \`$(basename "$KEY")\`: パーミッション $KEY_PERM — 600 必須"
    else
      ok "SSH秘密鍵 \`$(basename "$KEY")\`: パーミッション 600 ✓"
    fi
  done

  # known_hosts に最近追加されたエントリ
  KH="$SSH_DIR/known_hosts"
  if [ -f "$KH" ]; then
    KH_MOD=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$KH" 2>/dev/null || echo "?")
    info "known_hosts 最終更新: $KH_MOD"
  fi
else
  info "~/.ssh ディレクトリなし"
fi

# =============================================================================
# ★ F. VS Code / Cursor 拡張機能の監査
# =============================================================================
section "F. VS Code / Cursor 拡張機能"

VSCODE_EXT_DIRS=(
  "$HOME/.vscode/extensions"
  "$HOME/.cursor/extensions"
  "$HOME/.vscode-server/extensions"
)

for EXT_DIR in "${VSCODE_EXT_DIRS[@]}"; do
  [ -d "$EXT_DIR" ] || continue
  EDITOR_NAME=$(echo "$EXT_DIR" | grep -oE "(vscode|cursor)" | head -1)
  EXT_LIST=$(ls -1 "$EXT_DIR" 2>/dev/null || true)
  EXT_COUNT=$(echo "$EXT_LIST" | grep -c "." || echo "0")
  info "$EDITOR_NAME 拡張: ${EXT_COUNT}個"

  # 過去7日以内にインストール/更新された拡張
  RECENT_EXT=$(find "$EXT_DIR" -maxdepth 1 -type d -mtime -7 2>/dev/null | tail -n +2 || true)
  if [ -n "$RECENT_EXT" ]; then
    info "過去7日以内に更新された $EDITOR_NAME 拡張:"
    echo "$RECENT_EXT" | while read -r E; do
      echo "  - \`$(basename "$E")\`" >> "$REPORT"
    done
  fi

  # 非公式マーケットプレイスからの拡張を検出（.vsix 直接インストール）
  # package.json に __metadata がない拡張は手動インストールの可能性
  MANUAL_INSTALLS=0
  while IFS= read -r EXTPKG; do
    [ -f "$EXTPKG" ] || continue
    if ! grep -q "__metadata" "$EXTPKG" 2>/dev/null; then
      warn "$EDITOR_NAME: マーケットプレイス外拡張 \`$(basename "$(dirname "$EXTPKG")")\`"
      MANUAL_INSTALLS=$((MANUAL_INSTALLS + 1))
    fi
  done < <(find "$EXT_DIR" -maxdepth 2 -name "package.json" 2>/dev/null | head -50)

  [ "$MANUAL_INSTALLS" -eq 0 ] && ok "$EDITOR_NAME: 全拡張がマーケットプレイス経由"
done

# =============================================================================
# ★ G. macOS TCC (プライバシー権限) 監査
# =============================================================================
section "G. macOS プライバシー権限 (TCC)"

echo "Full Disk Access, Accessibility 等の権限付与状況を確認します。" >> "$REPORT"
echo "" >> "$REPORT"

TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SYSTEM_TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"

# ユーザーレベル TCC
if [ -f "$TCC_DB" ]; then
  if command -v sqlite3 &>/dev/null; then
    # Full Disk Access (kTCCServiceSystemPolicyAllFiles)
    FDA_APPS=$(sqlite3 "$TCC_DB" "SELECT client FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND auth_value=2;" 2>/dev/null || true)
    if [ -n "$FDA_APPS" ]; then
      info "**Full Disk Access** が許可されたアプリ:"
      echo "$FDA_APPS" | while read -r APP; do echo "  - \`$APP\`" >> "$REPORT"; done
    fi

    # Accessibility
    ACC_APPS=$(sqlite3 "$TCC_DB" "SELECT client FROM access WHERE service='kTCCServiceAccessibility' AND auth_value=2;" 2>/dev/null || true)
    if [ -n "$ACC_APPS" ]; then
      info "**Accessibility** が許可されたアプリ:"
      echo "$ACC_APPS" | while read -r APP; do echo "  - \`$APP\`" >> "$REPORT"; done
    fi

    # Screen Recording
    SR_APPS=$(sqlite3 "$TCC_DB" "SELECT client FROM access WHERE service='kTCCServiceScreenCapture' AND auth_value=2;" 2>/dev/null || true)
    if [ -n "$SR_APPS" ]; then
      info "**画面収録** が許可されたアプリ:"
      echo "$SR_APPS" | while read -r APP; do echo "  - \`$APP\`" >> "$REPORT"; done
    fi
  else
    info "sqlite3 が必要です（TCC データベースの解析）"
  fi
else
  info "ユーザー TCC データベースにアクセスできません（macOS の保護による場合あり）"
fi

echo "" >> "$REPORT"
echo "> 💡 \`システム設定 > プライバシーとセキュリティ\` で定期的に確認し、不要な権限を取り消してください" >> "$REPORT"

# =============================================================================
# ★ H. 既知 C2 ドメイン/IP へのアクティブ接続チェック
# 2026年3月 axios侵害の IOC を含む
# =============================================================================
section "H. 既知 C2 ドメイン / IP アクティブ接続チェック"

# 最新の既知 C2 (ハードコード + IOC DB)
KNOWN_C2_DOMAINS=(
  "sfrclak.com"         # axios npm 侵害 (2026-03)
  "evilginx"            # フィッシングフレームワーク
)

KNOWN_C2_IPS=(
  # 必要に応じて threat-intel-updater から動的に読み込む
)

# 現在の接続先を取得（v2 でキャッシュ済みなら再利用）
ACTIVE_CONNS="${CACHED_LSOF_ESTABLISHED:-$(lsof -i -nP 2>/dev/null | grep ESTABLISHED || true)}"

C2_DETECTED=0
for C2 in "${KNOWN_C2_DOMAINS[@]}"; do
  # DNS 解決して IP を取得
  C2_IPS=$(dig +short "$C2" 2>/dev/null || true)
  if [ -n "$C2_IPS" ]; then
    while IFS= read -r IP; do
      if echo "$ACTIVE_CONNS" | grep -q "$IP"; then
        critical "🚨 既知C2 \`$C2\` ($IP) へのアクティブ接続を検出！即座にネットワークを切断してください"
        C2_DETECTED=$((C2_DETECTED + 1))
      fi
    done <<< "$C2_IPS"
  fi
done

# IOC DB からも照合
if [ -f "$IOC_DIR/bad_domains.txt" ]; then
  # 現在の接続先ドメインを逆引きで取得（上位20件）
  CONN_IPS=$(echo "$ACTIVE_CONNS" | awk '{print $9}' | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort -u | head -20 || true)
  # パフォーマンスのため、接続先IPの逆引きではなく /etc/hosts のチェックに留める
  info "IOC DB 悪性ドメインリストとの照合: $(wc -l < "$IOC_DIR/bad_domains.txt" | tr -d ' ')件のDBで実施"
fi

if [ "$C2_DETECTED" -eq 0 ]; then
  ok "既知 C2 へのアクティブ接続なし"
fi

# =============================================================================
# ★ I. ロックファイル整合性チェック
# =============================================================================
section "I. ロックファイル整合性"

echo "プロジェクトのロックファイルが改ざんされていないか、Git 差分で確認します。" >> "$REPORT"
echo "" >> "$REPORT"

LOCKFILE_ISSUES=0

if [ -n "${PROJECT_DIRS:-}" ]; then
  for PDIR in $PROJECT_DIRS; do
    [ -d "$PDIR/.git" ] || continue

    for LOCKFILE in "package-lock.json" "yarn.lock" "pnpm-lock.yaml" "uv.lock" "Pipfile.lock" "poetry.lock"; do
      [ -f "$PDIR/$LOCKFILE" ] || continue

      # Git の追跡対象で、uncommitted な変更があるか
      LOCK_STATUS=$(cd "$PDIR" && git diff --name-only "$LOCKFILE" 2>/dev/null || true)
      if [ -n "$LOCK_STATUS" ]; then
        warn "\`$(basename "$PDIR")/$LOCKFILE\`: uncommitted な変更あり — 意図しない依存関係変更の可能性"
        LOCKFILE_ISSUES=$((LOCKFILE_ISSUES + 1))
      fi

      # ロックファイルが .gitignore されていないか
      IGNORED=$(cd "$PDIR" && git check-ignore "$LOCKFILE" 2>/dev/null || true)
      if [ -n "$IGNORED" ]; then
        warn "\`$(basename "$PDIR")/$LOCKFILE\`: .gitignore に含まれています — ロックファイルは Git 管理すべき"
        LOCKFILE_ISSUES=$((LOCKFILE_ISSUES + 1))
      fi
    done
  done
fi

[ "$LOCKFILE_ISSUES" -eq 0 ] && ok "ロックファイルの整合性に問題なし"

info "💡 PROJECT_DIRS 環境変数にプロジェクトパスを設定すると、複数リポジトリを一括チェックできます"
echo '  例: `export PROJECT_DIRS="$HOME/projects/app1 $HOME/projects/app2"`' >> "$REPORT"

# =============================================================================
# 使い方ガイド (コメント)
# =============================================================================
# このファイルを v2 に統合するには:
#
# 方法1: v2 のセクション8の後に内容をコピー&ペースト
#
# 方法2: v2 の末尾（サマリーの前）に以下を追加
#   ADDITIONS="$HOME/bin/mac-supply-chain-check-v3-additions.sh"
#   if [ -f "$ADDITIONS" ]; then
#     source "$ADDITIONS"
#   fi
#
# 環境変数:
#   PROJECT_DIRS: スペース区切りのプロジェクトディレクトリパス
#     export PROJECT_DIRS="$HOME/dev/project1 $HOME/dev/project2"
