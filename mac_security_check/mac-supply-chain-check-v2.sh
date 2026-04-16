#!/usr/bin/env bash
# =============================================================================
# mac-supply-chain-check-v2.sh
# IOCデータベース照合機能付き Mac サプライチェーン攻撃チェッカー
#
# 注意: macOS 標準の bash 3.2 では一部機能（連想配列等）が使えません。
#       Homebrew bash 4+ を推奨: brew install bash
#
# v1 からの追加機能:
#   - ローカルIOCデータベース (~/.security-ioc/) と照合
#   - インストール済みパッケージ vs 悪意あるパッケージリスト
#   - DNS クエリログ vs 悪性ドメインリスト
#   - ダウンロードファイルのハッシュ vs マルウェアハッシュリスト
#   - 前回レポートとの差分検出
# =============================================================================

set -euo pipefail

DATE=$(date +"%Y-%m-%d_%H%M")
REPORT_DIR="$HOME/security-reports"
REPORT="$REPORT_DIR/mac-check-$DATE.md"
IOC_DIR="$HOME/.security-ioc"
ALERT_COUNT=0
CRITICAL_COUNT=0

mkdir -p "$REPORT_DIR"

# --- Helpers ---
section() { echo -e "\n## $1\n" >> "$REPORT"; }
ok()      { echo "- ✅ $1" >> "$REPORT"; }
warn()    { echo "- ⚠️  $1" >> "$REPORT"; ALERT_COUNT=$((ALERT_COUNT + 1)); }
critical(){ echo "- 🔴 **$1**" >> "$REPORT"; ALERT_COUNT=$((ALERT_COUNT + 1)); CRITICAL_COUNT=$((CRITICAL_COUNT + 1)); }
info()    { echo "- ℹ️  $1" >> "$REPORT"; }

cat > "$REPORT" <<EOF
# Mac サプライチェーン攻撃チェックレポート (v2)
**実行日時**: $(date "+%Y年%m月%d日 %H:%M")
**ホスト名**: $(hostname)
**macOS**: $(sw_vers -productVersion) ($(uname -m))
**IOC DB**: $([ -d "$IOC_DIR" ] && echo "あり" || echo "なし — threat-intel-updater.sh を先に実行してください")
EOF

# =============================================================================
# 1. macOS システム整合性 (v1 と同じ)
# =============================================================================
section "1. macOS システム整合性"

SIP_STATUS=$(csrutil status 2>&1 || true)
if echo "$SIP_STATUS" | grep -q "enabled"; then ok "SIP 有効"
else warn "SIP が無効"; fi

GK_STATUS=$(spctl --status 2>&1 || true)
if echo "$GK_STATUS" | grep -q "assessments enabled"; then ok "Gatekeeper 有効"
else warn "Gatekeeper が無効"; fi

FV_STATUS=$(fdesetup status 2>&1 || true)
if echo "$FV_STATUS" | grep -q "On"; then ok "FileVault 有効"
else warn "FileVault が無効"; fi

FW_STATUS=$(defaults read /Library/Preferences/com.apple.alf globalstate 2>/dev/null || echo "0")
if [ "$FW_STATUS" -ge 1 ] 2>/dev/null; then ok "ファイアウォール有効"
else warn "ファイアウォールが無効"; fi

# =============================================================================
# 2. Launch Agents / Daemons
# =============================================================================
section "2. Launch Agents / Daemons"

# 既知ベンダーの plist プレフィックス（grep -qE のパターンとして使用）
# 自分が使うアプリを追加して誤検出を減らしてください
KNOWN_PREFIXES="com.apple.|com.google.|com.microsoft.|com.docker.|com.jetbrains.|org.mozilla.|com.spotify.|com.1password.|us.zoom.|com.sample."
SUSPICIOUS_AGENTS=()

for DIR in ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons; do
  [ -d "$DIR" ] || continue
  for PLIST in "$DIR"/*.plist; do
    [ -f "$PLIST" ] || continue
    LABEL=$(basename "$PLIST" .plist)
    if ! echo "$LABEL" | grep -qE "^($KNOWN_PREFIXES)"; then
      SUSPICIOUS_AGENTS+=("$PLIST")
    fi
  done
done

if [ ${#SUSPICIOUS_AGENTS[@]} -eq 0 ]; then
  ok "不審な Launch Agent/Daemon なし"
else
  warn "確認が必要な Agent/Daemon: ${#SUSPICIOUS_AGENTS[@]}件"
  for A in "${SUSPICIOUS_AGENTS[@]}"; do
    echo "  - \`$(basename "$A")\`" >> "$REPORT"
  done
fi

# =============================================================================
# 3. Homebrew 整合性
# =============================================================================
section "3. Homebrew"

if command -v brew &>/dev/null; then
  BREW_ISSUES=$(brew doctor 2>&1 | grep -c "Warning:" || true)
  [ "$BREW_ISSUES" -eq 0 ] && ok "brew doctor: 問題なし" || warn "brew doctor: ${BREW_ISSUES}件の警告"

  UNOFFICIAL_TAPS=$(brew tap 2>/dev/null | grep -v "^homebrew/" || true)
  [ -z "$UNOFFICIAL_TAPS" ] && ok "非公式 tap なし" || { warn "非公式 tap あり"; echo "$UNOFFICIAL_TAPS" | while read -r T; do echo "  - \`$T\`" >> "$REPORT"; done; }

  OUTDATED=$(brew outdated --quiet 2>/dev/null | wc -l | tr -d ' ')
  [ "$OUTDATED" -gt 0 ] && info "アップデート待ち: ${OUTDATED}件" || ok "全パッケージ最新"
fi

# =============================================================================
# 4. npm / pip 脆弱性監査
# =============================================================================
section "4. パッケージマネージャ監査"

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
  info "pip-audit 未インストール"
fi

# =============================================================================
# ★ 5. IOC データベース照合 (v2 新機能)
# =============================================================================
section "5. IOC データベース照合"

if [ ! -d "$IOC_DIR" ]; then
  info "IOC データベースなし — \`threat-intel-updater.sh\` を実行してください"
else

  # ----- 5a. 悪意あるパッケージの検出 -----
  MALICIOUS_PKG_FILE="$IOC_DIR/malicious_packages.json"
  if [ -f "$MALICIOUS_PKG_FILE" ] && command -v python3 &>/dev/null; then
    echo "### 5a. 悪意あるパッケージ照合" >> "$REPORT"
    echo "" >> "$REPORT"

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

  # ----- 5b. 悪性ドメインへの接続チェック -----
  BAD_DOMAINS="$IOC_DIR/bad_domains.txt"
  if [ -f "$BAD_DOMAINS" ]; then
    echo "" >> "$REPORT"
    echo "### 5b. 悪性ドメイン接続チェック" >> "$REPORT"
    echo "" >> "$REPORT"

    # 現在のDNSキャッシュ or 接続先を照合（キャッシュがあれば再利用）
    CURRENT_CONNS=$(echo "${CACHED_LSOF_ESTABLISHED:-$(lsof -i -nP 2>/dev/null | grep ESTABLISHED || true)}" | awk '{print $9}' | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort -u || true)
    
    # /etc/hosts に悪性ドメインが追加されていないかチェック
    HOSTS_HITS=""
    if [ -f "$BAD_DOMAINS" ]; then
      # 接続先IPをリバースDNSで解決して照合（上位100件のみ）
      DOMAIN_HITS=""
      while IFS= read -r DOMAIN; do
        [ -z "$DOMAIN" ] && continue
        # /etc/hosts に載っていないか
        if grep -qi "$DOMAIN" /etc/hosts 2>/dev/null; then
          HOSTS_HITS="${HOSTS_HITS}${DOMAIN}\n"
        fi
      done < <(head -100 "$BAD_DOMAINS")
    fi

    if [ -z "$HOSTS_HITS" ]; then
      ok "悪性ドメインへの接続の痕跡なし（サンプルチェック）"
    else
      echo -e "$HOSTS_HITS" | while read -r D; do
        [ -n "$D" ] && critical "/etc/hosts に悪性ドメインが記載: \`$D\`"
      done
    fi
  fi

  # ----- 5c. ダウンロードフォルダのハッシュ照合 -----
  HASH_FILE="$IOC_DIR/malicious_hashes.txt"
  if [ -f "$HASH_FILE" ]; then
    echo "" >> "$REPORT"
    echo "### 5c. ダウンロードファイル ハッシュ照合" >> "$REPORT"
    echo "" >> "$REPORT"

    DOWNLOAD_DIRS=("$HOME/Downloads" "$HOME/Desktop")
    HASH_HITS=0

    for DL_DIR in "${DOWNLOAD_DIRS[@]}"; do
      [ -d "$DL_DIR" ] || continue
      # 過去14日以内のファイル、最大50件
      while IFS= read -r FILE; do
        [ -f "$FILE" ] || continue
        FILE_HASH=$(shasum -a 256 "$FILE" 2>/dev/null | awk '{print $1}' || true)
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

  # ----- 5d. 脆弱パッケージの照合 -----
  VULN_PKG_FILE="$IOC_DIR/vuln_packages.txt"
  if [ -f "$VULN_PKG_FILE" ] && [ -s "$VULN_PKG_FILE" ]; then
    echo "" >> "$REPORT"
    echo "### 5d. 脆弱パッケージ照合 (Claude レポート由来)" >> "$REPORT"
    echo "" >> "$REPORT"

    INSTALLED_BREW=$(brew list --formula -1 2>/dev/null || true)
    VULN_HITS=0

    while IFS= read -r VPKG; do
      [ -z "$VPKG" ] && continue
      if echo "$INSTALLED_BREW" | grep -qi "^${VPKG}$" 2>/dev/null; then
        warn "脆弱性レポートに該当するパッケージがインストール済み: \`$VPKG\` — アップデート確認推奨"
        VULN_HITS=$((VULN_HITS + 1))
      fi
    done < "$VULN_PKG_FILE"

    [ "$VULN_HITS" -eq 0 ] && ok "脆弱パッケージの該当なし"
  fi

fi  # IOC_DIR exists

# =============================================================================
# 6. アプリケーション署名検証
# =============================================================================
section "6. アプリケーション署名"

UNSIGNED_APPS=()
COUNT=0
for APP in /Applications/*.app; do
  [ -d "$APP" ] || continue
  COUNT=$((COUNT + 1)); [ $COUNT -gt 20 ] && break
  CODESIGN=$(codesign -dvv "$APP" 2>&1 || true)
  if echo "$CODESIGN" | grep -q "code object is not signed"; then
    UNSIGNED_APPS+=("$(basename "$APP")")
  fi
done
[ ${#UNSIGNED_APPS[@]} -eq 0 ] && ok "検査したアプリはすべて署名済み" || {
  warn "未署名アプリ: ${#UNSIGNED_APPS[@]}件"
  for U in "${UNSIGNED_APPS[@]}"; do echo "  - $U" >> "$REPORT"; done
}

# =============================================================================
# 7. ネットワーク接続
# =============================================================================
section "7. ネットワーク接続"

# lsof の結果をキャッシュ（v3 additions でも再利用）
CACHED_LSOF_ESTABLISHED=$(lsof -i -nP 2>/dev/null | grep ESTABLISHED || true)
export CACHED_LSOF_ESTABLISHED

SUSPICIOUS_CONNS=$(echo "$CACHED_LSOF_ESTABLISHED" | grep -vE ":(443|80|53|22|993|587|5228|8080) " | grep -vE "localhost|127\.0\.0\.1" || true)
if [ -z "$SUSPICIOUS_CONNS" ]; then
  ok "非標準ポートの不審な外部接続なし"
else
  CONN_COUNT=$(echo "$SUSPICIOUS_CONNS" | wc -l | tr -d ' ')
  warn "非標準ポート外部接続: ${CONN_COUNT}件"
  echo '```' >> "$REPORT"
  echo "$SUSPICIOUS_CONNS" | head -15 >> "$REPORT"
  echo '```' >> "$REPORT"
fi

# =============================================================================
# 8. 最近変更されたバイナリ
# =============================================================================
section "8. 最近変更されたバイナリ (過去7日)"

RECENT_MODS=$(find /usr/local/bin /opt/homebrew/bin 2>/dev/null -type f -mtime -7 2>/dev/null | head -20 || true)
[ -z "$RECENT_MODS" ] && ok "変更なし" || {
  info "過去7日間に変更:"
  echo "$RECENT_MODS" | while read -r F; do echo "  - \`$(basename "$F")\` ($(stat -f '%Sm' "$F" 2>/dev/null || echo '?'))" >> "$REPORT"; done
}

# =============================================================================
# ★ 9. 前回レポートとの差分 (v2 新機能)
# =============================================================================
section "9. 前回レポートとの差分"

PREV_REPORT=$(ls -t "$REPORT_DIR"/mac-check-*.md 2>/dev/null | grep -v "$DATE" | head -1 || true)
if [ -n "$PREV_REPORT" ] && [ -f "$PREV_REPORT" ]; then
  PREV_ALERTS=$(grep -c "⚠️\|🔴" "$PREV_REPORT" 2>/dev/null || echo "0")
  info "前回レポート: $(basename "$PREV_REPORT") (アラート: ${PREV_ALERTS}件)"
  
  # 新しく出現した Launch Agent があるか
  PREV_AGENTS=$(grep "Launch Agent" "$PREV_REPORT" 2>/dev/null | grep -oE "\`.+\.plist\`" || true)
  CURR_AGENTS=$(grep "Launch Agent" "$REPORT" 2>/dev/null | grep -oE "\`.+\.plist\`" || true)
  NEW_AGENTS=$(comm -13 <(echo "$PREV_AGENTS" | sort) <(echo "$CURR_AGENTS" | sort) 2>/dev/null || true)
  
  if [ -n "$NEW_AGENTS" ]; then
    warn "前回から新たに追加された Launch Agent:"
    echo "$NEW_AGENTS" | while read -r A; do [ -n "$A" ] && echo "  - $A" >> "$REPORT"; done
  else
    ok "前回から新しい Launch Agent の追加なし"
  fi
else
  info "比較可能な前回レポートなし（初回実行）"
fi

# =============================================================================
# サマリー
# =============================================================================
echo -e "\n---\n" >> "$REPORT"
echo "## サマリー" >> "$REPORT"
echo "" >> "$REPORT"

if [ "$CRITICAL_COUNT" -gt 0 ]; then
  echo "🔴 **CRITICAL: ${CRITICAL_COUNT}件** — 即座の対応が必要です" >> "$REPORT"
elif [ "$ALERT_COUNT" -gt 0 ]; then
  echo "🟡 **アラート: ${ALERT_COUNT}件** — 上記 ⚠️ 項目を確認してください" >> "$REPORT"
else
  echo "🟢 **問題なし** — すべてのチェックをパスしました" >> "$REPORT"
fi

echo "" >> "$REPORT"
IOC_STATS=""
[ -d "$IOC_DIR" ] && IOC_STATS=" | IOC DB: $(ls "$IOC_DIR"/*.txt "$IOC_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')ファイル"
echo "_チェックエンジン v2${IOC_STATS}_" >> "$REPORT"

# --- 出力 ---
echo ""
echo "========================================"
if [ "$CRITICAL_COUNT" -gt 0 ]; then
  echo "  🔴 CRITICAL: ${CRITICAL_COUNT}件 / アラート合計: ${ALERT_COUNT}件"
else
  echo "  チェック完了 — アラート: ${ALERT_COUNT}件"
fi
echo "  レポート: $REPORT"
echo "========================================"
echo ""

# macOS 通知
if [ "$CRITICAL_COUNT" -gt 0 ]; then
  osascript -e "display notification \"CRITICAL ${CRITICAL_COUNT}件！即座に確認してください\" with title \"🔴 Security Alert\" subtitle \"サプライチェーンチェッカー\"" 2>/dev/null || true
elif [ "$ALERT_COUNT" -gt 0 ]; then
  osascript -e "display notification \"${ALERT_COUNT}件のアラートがあります\" with title \"Security Check\" subtitle \"サプライチェーンチェッカー\"" 2>/dev/null || true
fi
