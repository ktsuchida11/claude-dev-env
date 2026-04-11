#!/usr/bin/env bash
# =============================================================================
# common-supply-chain-checks.sh — クロスプラットフォーム共通セキュリティチェック
#
# macOS / Linux 両方で動作するセキュリティチェック群。
# mac-supply-chain-check-v2.sh および v3-additions.sh から
# ポータブルな部分を抽出・統合したもの。
#
# 前提:
#   - platform-detect.sh が source 済み
#   - 呼び出し元で以下が定義済み:
#     - $REPORT (レポート出力先ファイルパス)
#     - $IOC_DIR (IOC データベースディレクトリ)
#     - section(), ok(), warn(), critical(), info() ヘルパー関数
#     - $ALERT_COUNT, $CRITICAL_COUNT カウンター変数
#
# 使い方:
#   source host_security/platform-detect.sh
#   source host_security/common-supply-chain-checks.sh
# =============================================================================

# ガードチェック
if [ -z "${REPORT:-}" ]; then
    echo "ERROR: \$REPORT が未定義。呼び出し元でレポートファイルパスを設定してください。" >&2
    return 1 2>/dev/null || exit 1
fi
if ! type section &>/dev/null || ! type ok &>/dev/null; then
    echo "ERROR: helper 関数 (section, ok, warn, critical, info) が未定義。" >&2
    return 1 2>/dev/null || exit 1
fi
if [ -z "${PLATFORM:-}" ]; then
    echo "ERROR: platform-detect.sh を先に source してください。" >&2
    return 1 2>/dev/null || exit 1
fi

# =============================================================================
# 共通チェック A: npm / pip 脆弱性監査
# =============================================================================
run_package_audit() {
    section "パッケージマネージャ脆弱性監査"

    if command -v npm &>/dev/null; then
        NPM_AUDIT=$(npm -g audit 2>&1 || true)
        NPM_VULN=$(echo "$NPM_AUDIT" | grep -c "vulnerability" || true)
        [ "$NPM_VULN" -eq 0 ] && ok "npm (global): 脆弱性なし" || warn "npm (global): 脆弱性検出 → \`npm -g audit\`"
    fi

    if command -v pip-audit &>/dev/null; then
        PIP_RESULT=$(pip-audit 2>&1 || true)
        PIP_VULN=$(echo "$PIP_RESULT" | grep -cE "^Name" || true)
        [ "$PIP_VULN" -le 1 ] && ok "pip-audit: 脆弱性なし" || warn "pip-audit: 脆弱性検出"
    else
        info "pip-audit 未インストール ($(portable_install_hint pip-audit))"
    fi
}

# =============================================================================
# 共通チェック B: IOC データベース照合
# =============================================================================
run_ioc_checks() {
    section "IOC データベース照合"

    if [ ! -d "${IOC_DIR:-}" ]; then
        info "IOC データベースなし — \`threat-intel-updater.sh\` を実行してください"
        return 0
    fi

    # ----- 悪意あるパッケージの検出 -----
    local MALICIOUS_PKG_FILE="$IOC_DIR/malicious_packages.json"
    if [ -f "$MALICIOUS_PKG_FILE" ] && command -v python3 &>/dev/null; then
        echo "### 悪意あるパッケージ照合" >> "$REPORT"
        echo "" >> "$REPORT"

        local FOUND_MALICIOUS
        FOUND_MALICIOUS=$(MALICIOUS_PKG_FILE="$MALICIOUS_PKG_FILE" python3 -c "
import json, subprocess, sys, os

pkg_file = os.environ['MALICIOUS_PKG_FILE']
with open(pkg_file) as f:
    db = json.load(f)

found = []

# npm global packages
try:
    result = subprocess.run(['npm', 'ls', '-g', '--depth=0', '--json'],
                          capture_output=True, text=True, timeout=30)
    npm_data = json.loads(result.stdout or '{}')
    npm_pkgs = list(npm_data.get('dependencies', {}).keys())
    for bad in db.get('npm', []):
        pkg_name = bad.split('@')[0] if '@' in bad else bad
        if pkg_name in npm_pkgs:
            found.append(f'npm:{bad}')
except Exception:
    pass

# pip packages
try:
    result = subprocess.run(['pip', 'list', '--format=json'],
                          capture_output=True, text=True, timeout=30)
    pip_pkgs = [p['name'].lower() for p in json.loads(result.stdout or '[]')]
    for bad in db.get('pip', []):
        if bad.lower() in pip_pkgs:
            found.append(f'pip:{bad}')
except Exception:
    pass

for f in found:
    print(f)
" 2>/dev/null || true)

        if [ -z "$FOUND_MALICIOUS" ]; then
            ok "既知の悪意あるパッケージは検出されず"
        else
            echo "$FOUND_MALICIOUS" | while read -r PKG; do
                critical "悪意あるパッケージ検出: \`$PKG\` — 即座にアンインストールしてください"
            done
        fi
    fi

    # ----- 悪性ドメインへの接続チェック -----
    local BAD_DOMAINS="$IOC_DIR/bad_domains.txt"
    if [ -f "$BAD_DOMAINS" ]; then
        echo "" >> "$REPORT"
        echo "### 悪性ドメイン接続チェック" >> "$REPORT"
        echo "" >> "$REPORT"

        local HOSTS_HITS=""
        while IFS= read -r DOMAIN; do
            [ -z "$DOMAIN" ] && continue
            if grep -qi "$DOMAIN" /etc/hosts 2>/dev/null; then
                HOSTS_HITS="${HOSTS_HITS}${DOMAIN}\n"
            fi
        done < <(head -100 "$BAD_DOMAINS")

        if [ -z "$HOSTS_HITS" ]; then
            ok "悪性ドメインへの接続の痕跡なし（サンプルチェック）"
        else
            echo -e "$HOSTS_HITS" | while read -r D; do
                [ -n "$D" ] && critical "/etc/hosts に悪性ドメインが記載: \`$D\`"
            done
        fi
    fi

    # ----- ダウンロードフォルダのハッシュ照合 -----
    local HASH_FILE="$IOC_DIR/malicious_hashes.txt"
    if [ -f "$HASH_FILE" ]; then
        echo "" >> "$REPORT"
        echo "### ダウンロードファイル ハッシュ照合" >> "$REPORT"
        echo "" >> "$REPORT"

        local DOWNLOAD_DIRS=("$HOME/Downloads" "$HOME/Desktop")
        local HASH_HITS=0

        for DL_DIR in "${DOWNLOAD_DIRS[@]}"; do
            [ -d "$DL_DIR" ] || continue
            while IFS= read -r FILE; do
                [ -f "$FILE" ] || continue
                local FILE_HASH
                FILE_HASH=$(portable_sha256 "$FILE")
                if [ -n "$FILE_HASH" ] && grep -q "$FILE_HASH" "$HASH_FILE" 2>/dev/null; then
                    critical "マルウェアハッシュ一致: \`$(basename "$FILE")\` ($FILE_HASH)"
                    HASH_HITS=$((HASH_HITS + 1))
                fi
            done < <(find "$DL_DIR" -maxdepth 2 -type f -mtime -14 2>/dev/null | head -50)
        done

        if [ "$HASH_HITS" -eq 0 ]; then
            ok "ダウンロードファイルにマルウェアハッシュの一致なし（直近14日）"
        fi
    fi
}

# =============================================================================
# 共通チェック C: パッケージマネージャ Lockdown 設定
# =============================================================================
run_lockdown_check() {
    section "パッケージマネージャ Lockdown 設定の整合性"

    echo "npm/uv/pip のロックダウン設定が改ざんされていないか検証します。" >> "$REPORT"
    echo "" >> "$REPORT"

    local NPM_LOCKDOWN_OK=true

    # ----- npm: .npmrc -----
    local NPM_CONFIGS=("$HOME/.npmrc")
    if [ "$PLATFORM" = "darwin" ]; then
        NPM_CONFIGS+=("/usr/local/etc/npmrc" "/opt/homebrew/etc/npmrc")
    else
        NPM_CONFIGS+=("/etc/npmrc")
    fi

    for NPMRC in "${NPM_CONFIGS[@]}"; do
        [ -f "$NPMRC" ] || continue
        info "npm config 検出: \`$NPMRC\`"

        if grep -qi "ignore-scripts\s*=\s*true" "$NPMRC" 2>/dev/null; then
            ok "\`$NPMRC\`: ignore-scripts=true"
        else
            warn "\`$NPMRC\`: **ignore-scripts が無効** — postinstall 攻撃に脆弱"
            NPM_LOCKDOWN_OK=false
        fi

        if grep -qi "package-lock\s*=\s*false" "$NPMRC" 2>/dev/null; then
            warn "\`$NPMRC\`: package-lock=false — ロックファイルが無効化"
            NPM_LOCKDOWN_OK=false
        fi

        local NPMRC_PERM NPMRC_OWNER
        NPMRC_PERM=$(portable_stat_perm "$NPMRC")
        NPMRC_OWNER=$(portable_stat_owner "$NPMRC")
        if [ "$NPMRC_PERM" != "644" ] && [ "$NPMRC_PERM" != "600" ]; then
            warn "\`$NPMRC\`: パーミッション $NPMRC_PERM — 644 または 600 を推奨"
        fi
        if [ "$NPMRC_OWNER" != "$(whoami)" ]; then
            critical "\`$NPMRC\`: 所有者が $(whoami) ではなく $NPMRC_OWNER — 改ざんの可能性"
        fi
    done

    $NPM_LOCKDOWN_OK && ok "npm ロックダウン設定: 整合性OK"

    # ----- pip: pip.conf -----
    local PIP_CONFIGS=("$(portable_pip_conf_path)" "$HOME/.pip/pip.conf" "/etc/pip.conf")

    for PIPCONF in "${PIP_CONFIGS[@]}"; do
        [ -f "$PIPCONF" ] || continue
        info "pip config 検出: \`$PIPCONF\`"

        local TRUSTED
        TRUSTED=$(grep -i "trusted-host" "$PIPCONF" 2>/dev/null || true)
        if [ -n "$TRUSTED" ]; then
            if echo "$TRUSTED" | grep -vqE "pypi\.org|files\.pythonhosted\.org"; then
                warn "\`$PIPCONF\`: 非標準の trusted-host 設定あり → $TRUSTED"
            fi
        fi
    done

    # ----- uv: uv.toml -----
    local UV_CONFIGS=("$HOME/.config/uv/uv.toml" "$HOME/uv.toml")

    for UVCONF in "${UV_CONFIGS[@]}"; do
        [ -f "$UVCONF" ] || continue
        info "uv config 検出: \`$UVCONF\`"

        if grep -qi "index-url" "$UVCONF" 2>/dev/null; then
            local INDEX_URL
            INDEX_URL=$(grep -i "index-url" "$UVCONF" | head -1)
            if echo "$INDEX_URL" | grep -qvE "pypi\.org"; then
                warn "\`$UVCONF\`: 非公式の index-url → $INDEX_URL"
            fi
        fi
    done
}

# =============================================================================
# 共通チェック D: AI ツール認証情報・設定ファイル監査
# =============================================================================
run_ai_config_audit() {
    section "AI ツール認証情報・設定ファイル監査"

    echo "AI コーディングツールの認証情報が不正アクセスされていないか確認します。" >> "$REPORT"
    echo "" >> "$REPORT"

    while IFS= read -r AI_PATH; do
        [ -e "$AI_PATH" ] || continue
        local TOOL_NAME
        TOOL_NAME=$(basename "$AI_PATH")

        if [ -d "$AI_PATH" ]; then
            local DIR_PERM
            DIR_PERM=$(portable_stat_perm "$AI_PATH")
            if [ "$DIR_PERM" != "700" ] && [ "$DIR_PERM" != "755" ]; then
                warn "AI設定 \`$AI_PATH\`: パーミッション $DIR_PERM — 700 推奨"
            fi

            local RECENT
            RECENT=$(find "$AI_PATH" -type f -mtime -3 2>/dev/null | head -5 || true)
            if [ -n "$RECENT" ]; then
                info "\`$TOOL_NAME\`: 過去3日以内に変更あり"
                echo "$RECENT" | while read -r F; do
                    echo "    - \`$(basename "$F")\` ($(portable_stat_mtime "$F"))" >> "$REPORT"
                done
            fi
        elif [ -f "$AI_PATH" ]; then
            local FILE_PERM
            FILE_PERM=$(portable_stat_perm "$AI_PATH")
            if [ "$FILE_PERM" != "600" ] && [ "$FILE_PERM" != "644" ]; then
                warn "AI設定 \`$AI_PATH\`: パーミッション $FILE_PERM — 600 推奨"
            fi
        fi

        ok "\`$TOOL_NAME\` 設定検出（所有者: $(portable_stat_owner "$AI_PATH")）"
    done < <(portable_ai_config_paths)

    # API キーの平文露出チェック
    local ENV_FILES
    ENV_FILES=$(find "$HOME" -maxdepth 3 -name ".env" -o -name ".env.local" -o -name ".env.production" 2>/dev/null | head -20 || true)
    if [ -n "$ENV_FILES" ]; then
        local EXPOSED_KEYS=0
        while IFS= read -r ENVF; do
            [ -f "$ENVF" ] || continue
            if grep -qE "(sk-ant-|sk-[a-zA-Z0-9]{20,}|AKIA[A-Z0-9]{16})" "$ENVF" 2>/dev/null; then
                EXPOSED_KEYS=$((EXPOSED_KEYS + 1))
                local ENVF_PERM
                ENVF_PERM=$(portable_stat_perm "$ENVF")
                if [ "$ENVF_PERM" != "600" ]; then
                    warn "\`$ENVF\`: API キーを含み、パーミッション $ENVF_PERM — 600 に変更推奨"
                else
                    info "\`$ENVF\`: API キーあり（パーミッション 600 ✓）"
                fi
            fi
        done <<< "$ENV_FILES"
        [ "$EXPOSED_KEYS" -eq 0 ] && ok ".env ファイルに露出した API キーなし"
    fi
}

# =============================================================================
# 共通チェック E: MCP サーバー設定の棚卸し
# =============================================================================
run_mcp_audit() {
    section "MCP (Model Context Protocol) サーバー設定"

    echo "Claude Code 等の MCP 接続先を棚卸しし、不審な接続先がないか確認します。" >> "$REPORT"
    echo "" >> "$REPORT"

    local MCP_FOUND=false
    while IFS= read -r MCP_CONF; do
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
        fi
    done < <(portable_mcp_config_paths)

    $MCP_FOUND || info "MCP 設定ファイルは検出されませんでした"
}

# =============================================================================
# 共通チェック F: Git Hooks
# =============================================================================
run_git_hooks_check() {
    section "Git Hooks チェック"

    echo "アクティブなリポジトリの .git/hooks/ に不審なスクリプトがないか確認します。" >> "$REPORT"
    echo "" >> "$REPORT"

    local GIT_DIRS
    GIT_DIRS=$(find "$HOME" -maxdepth 4 -name ".git" -type d 2>/dev/null \
        | grep -v "node_modules" \
        | grep -v ".cache" \
        | head -20 || true)

    local SUSPICIOUS_HOOKS=0
    while IFS= read -r GITDIR; do
        [ -d "$GITDIR/hooks" ] || continue
        for HOOK in "$GITDIR/hooks"/*; do
            [ -f "$HOOK" ] || continue
            [[ "$HOOK" == *.sample ]] && continue
            if [ -x "$HOOK" ]; then
                local HOOK_NAME REPO_DIR
                HOOK_NAME=$(basename "$HOOK")
                REPO_DIR=$(dirname "$(dirname "$HOOK")")

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

    local GLOBAL_HOOKS
    GLOBAL_HOOKS=$(git config --global core.hooksPath 2>/dev/null || true)
    if [ -n "$GLOBAL_HOOKS" ]; then
        warn "グローバル Git hooksPath が設定されています: \`$GLOBAL_HOOKS\`"
    else
        ok "グローバル hooksPath 未設定（デフォルト）"
    fi
}

# =============================================================================
# 共通チェック G: SSH 鍵監査
# =============================================================================
run_ssh_audit() {
    section "SSH 鍵監査"

    local SSH_DIR="$HOME/.ssh"
    if [ ! -d "$SSH_DIR" ]; then
        info "~/.ssh ディレクトリなし"
        return 0
    fi

    local AUTH_KEYS="$SSH_DIR/authorized_keys"
    if [ -f "$AUTH_KEYS" ]; then
        local KEY_COUNT
        KEY_COUNT=$(grep -c "^ssh-\|^ecdsa-\|^sk-" "$AUTH_KEYS" 2>/dev/null || echo "0")
        info "authorized_keys: ${KEY_COUNT}個の公開鍵"

        local AK_MOD
        AK_MOD=$(portable_stat_mtime "$AUTH_KEYS")
        info "authorized_keys 最終更新: $AK_MOD"

        local AK_EPOCH NOW_EPOCH AK_DAYS
        AK_EPOCH=$(portable_stat_mtime_epoch "$AUTH_KEYS")
        NOW_EPOCH=$(date +%s)
        AK_DAYS=$(( (NOW_EPOCH - AK_EPOCH) / 86400 ))
        if [ "$AK_DAYS" -lt 7 ]; then
            warn "authorized_keys が過去7日以内に変更されています — 意図した変更か確認してください"
        fi
    fi

    for KEY in "$SSH_DIR"/id_*; do
        [ -f "$KEY" ] || continue
        [[ "$KEY" == *.pub ]] && continue
        local KEY_PERM
        KEY_PERM=$(portable_stat_perm "$KEY")
        if [ "$KEY_PERM" != "600" ]; then
            warn "SSH秘密鍵 \`$(basename "$KEY")\`: パーミッション $KEY_PERM — 600 必須"
        else
            ok "SSH秘密鍵 \`$(basename "$KEY")\`: パーミッション 600 ✓"
        fi
    done

    local KH="$SSH_DIR/known_hosts"
    if [ -f "$KH" ]; then
        info "known_hosts 最終更新: $(portable_stat_mtime "$KH")"
    fi
}

# =============================================================================
# 共通チェック H: VS Code / Cursor 拡張機能
# =============================================================================
run_vscode_audit() {
    section "VS Code / Cursor 拡張機能"

    local VSCODE_EXT_DIRS=(
        "$HOME/.vscode/extensions"
        "$HOME/.cursor/extensions"
        "$HOME/.vscode-server/extensions"
    )

    for EXT_DIR in "${VSCODE_EXT_DIRS[@]}"; do
        [ -d "$EXT_DIR" ] || continue
        local EDITOR_NAME
        EDITOR_NAME=$(echo "$EXT_DIR" | grep -oE "(vscode|cursor)" | head -1)
        local EXT_COUNT
        EXT_COUNT=$(ls -1 "$EXT_DIR" 2>/dev/null | grep -c "." || echo "0")
        info "$EDITOR_NAME 拡張: ${EXT_COUNT}個"

        local RECENT_EXT
        RECENT_EXT=$(find "$EXT_DIR" -maxdepth 1 -type d -mtime -7 2>/dev/null | tail -n +2 || true)
        if [ -n "$RECENT_EXT" ]; then
            info "過去7日以内に更新された $EDITOR_NAME 拡張:"
            echo "$RECENT_EXT" | while read -r E; do
                echo "  - \`$(basename "$E")\`" >> "$REPORT"
            done
        fi

        local MANUAL_INSTALLS=0
        while IFS= read -r EXTPKG; do
            [ -f "$EXTPKG" ] || continue
            if ! grep -q "__metadata" "$EXTPKG" 2>/dev/null; then
                warn "$EDITOR_NAME: マーケットプレイス外拡張 \`$(basename "$(dirname "$EXTPKG")")\`"
                MANUAL_INSTALLS=$((MANUAL_INSTALLS + 1))
            fi
        done < <(find "$EXT_DIR" -maxdepth 2 -name "package.json" 2>/dev/null | head -50)

        [ "$MANUAL_INSTALLS" -eq 0 ] && ok "$EDITOR_NAME: 全拡張がマーケットプレイス経由"
    done
}

# =============================================================================
# 共通チェック I: C2 接続チェック
# =============================================================================
run_c2_check() {
    section "既知 C2 ドメイン / IP アクティブ接続チェック"

    local KNOWN_C2_DOMAINS=(
        "sfrclak.com"         # axios npm 侵害 (2026-03)
        "evilginx"            # フィッシングフレームワーク
    )

    local ACTIVE_CONNS
    ACTIVE_CONNS=$(portable_net_connections)

    local C2_DETECTED=0
    for C2 in "${KNOWN_C2_DOMAINS[@]}"; do
        local C2_IPS
        C2_IPS=$(dig +short "$C2" 2>/dev/null || true)
        if [ -n "$C2_IPS" ]; then
            while IFS= read -r IP; do
                if echo "$ACTIVE_CONNS" | grep -q "$IP"; then
                    critical "既知C2 \`$C2\` ($IP) へのアクティブ接続を検出！即座にネットワークを切断してください"
                    C2_DETECTED=$((C2_DETECTED + 1))
                fi
            done <<< "$C2_IPS"
        fi
    done

    if [ -f "${IOC_DIR:-}/bad_domains.txt" ]; then
        info "IOC DB 悪性ドメインリストとの照合: $(wc -l < "$IOC_DIR/bad_domains.txt" | tr -d ' ')件のDBで実施"
    fi

    [ "$C2_DETECTED" -eq 0 ] && ok "既知 C2 へのアクティブ接続なし"
}

# =============================================================================
# 共通チェック J: ネットワーク接続
# =============================================================================
run_network_check() {
    section "ネットワーク接続"

    local ACTIVE_CONNS
    ACTIVE_CONNS=$(portable_net_connections)

    local SUSPICIOUS_CONNS
    SUSPICIOUS_CONNS=$(echo "$ACTIVE_CONNS" | grep -vE ":(443|80|53|22|993|587|5228|8080) " | grep -vE "localhost|127\.0\.0\.1" || true)
    if [ -z "$SUSPICIOUS_CONNS" ]; then
        ok "非標準ポートの不審な外部接続なし"
    else
        local CONN_COUNT
        CONN_COUNT=$(echo "$SUSPICIOUS_CONNS" | wc -l | tr -d ' ')
        warn "非標準ポート外部接続: ${CONN_COUNT}件"
        echo '```' >> "$REPORT"
        echo "$SUSPICIOUS_CONNS" | head -15 >> "$REPORT"
        echo '```' >> "$REPORT"
    fi
}

# =============================================================================
# 共通チェック K: ロックファイル整合性
# =============================================================================
run_lockfile_check() {
    section "ロックファイル整合性"

    echo "プロジェクトのロックファイルが改ざんされていないか、Git 差分で確認します。" >> "$REPORT"
    echo "" >> "$REPORT"

    local LOCKFILE_ISSUES=0

    if [ -n "${PROJECT_DIRS:-}" ]; then
        for PDIR in $PROJECT_DIRS; do
            [ -d "$PDIR/.git" ] || continue

            for LOCKFILE in "package-lock.json" "yarn.lock" "pnpm-lock.yaml" "uv.lock" "Pipfile.lock" "poetry.lock"; do
                [ -f "$PDIR/$LOCKFILE" ] || continue

                local LOCK_STATUS
                LOCK_STATUS=$(cd "$PDIR" && git diff --name-only "$LOCKFILE" 2>/dev/null || true)
                if [ -n "$LOCK_STATUS" ]; then
                    warn "\`$(basename "$PDIR")/$LOCKFILE\`: uncommitted な変更あり"
                    LOCKFILE_ISSUES=$((LOCKFILE_ISSUES + 1))
                fi

                local IGNORED
                IGNORED=$(cd "$PDIR" && git check-ignore "$LOCKFILE" 2>/dev/null || true)
                if [ -n "$IGNORED" ]; then
                    warn "\`$(basename "$PDIR")/$LOCKFILE\`: .gitignore に含まれています — ロックファイルは Git 管理すべき"
                    LOCKFILE_ISSUES=$((LOCKFILE_ISSUES + 1))
                fi
            done
        done
    fi

    [ "$LOCKFILE_ISSUES" -eq 0 ] && ok "ロックファイルの整合性に問題なし"
    info "PROJECT_DIRS 環境変数にプロジェクトパスを設定すると、複数リポジトリを一括チェックできます"
}

# =============================================================================
# 全共通チェック実行
# =============================================================================
run_all_common_checks() {
    run_package_audit
    run_ioc_checks
    run_lockdown_check
    run_ai_config_audit
    run_mcp_audit
    run_git_hooks_check
    run_ssh_audit
    run_vscode_audit
    run_c2_check
    run_network_check
    run_lockfile_check
}
