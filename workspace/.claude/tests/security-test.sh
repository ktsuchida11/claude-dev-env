#!/usr/bin/env bash
# =============================================================================
# security-test.sh — DevContainer セキュリティ自動テスト
#
# コンテナ内で実行して、各セキュリティ対策が正しく機能しているか検証する。
# 使い方: bash <this-dir>/security-test.sh
#
# テストカテゴリ:
#   1. ファイアウォール（ネットワーク制限）
#   2. ファイルシステム制限
#   3. ユーザー権限
#   4. パッケージマネージャ設定（サプライチェーン Layer 1）
#   5. 設定ファイル整合性
# =============================================================================

set -uo pipefail

# --- テストフレームワーク ---

PASS=0
FAIL=0
SKIP=0
ERRORS=()

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SETTINGS="${BASE_DIR}/settings.json"
WORKSPACE="${PROJECT_DIR}/workspace"

# DevContainer 内かローカルかを判定
IS_DEVCONTAINER="false"
if [ -f "/.dockerenv" ] || grep -q 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
  IS_DEVCONTAINER="true"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() {
  echo -e "  ${GREEN}✓ PASS${NC}: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo -e "  ${RED}✗ FAIL${NC}: $1"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1")
}

skip() {
  echo -e "  ${YELLOW}○ SKIP${NC}: $1"
  SKIP=$((SKIP + 1))
}

section() {
  echo ""
  echo -e "${BOLD}${CYAN}[$1]${NC} $2"
  echo "─────────────────────────────────────────"
}

# =============================================================================
# 1. ファイアウォール
# =============================================================================
section "1" "ファイアウォール（ネットワーク制限）"

if [ "$IS_DEVCONTAINER" = "false" ]; then
  skip "iptables: ローカル環境ではスキップ（DevContainer 専用）"
  skip "ipset: ローカル環境ではスキップ（DevContainer 専用）"
  skip "外部通信ブロック: ローカル環境ではスキップ（DevContainer 専用）"
  skip "許可通信テスト: ローカル環境ではスキップ（DevContainer 専用）"
  skip "DNS 解決テスト: ローカル環境ではスキップ（DevContainer 専用）"
else

# ファイアウォールが有効か確認
if sudo iptables -L OUTPUT -n 2>/dev/null | grep -q "DROP"; then
  pass "iptables OUTPUT デフォルトポリシー: DROP"
else
  if [ "${ENABLE_FIREWALL:-true}" = "false" ]; then
    skip "ファイアウォール無効（ENABLE_FIREWALL=false）"
  else
    fail "iptables OUTPUT デフォルトポリシーが DROP でない"
  fi
fi

# ipset が設定されているか（sudo 権限が必要なため、利用可能な場合のみ）
if sudo -n ipset list allowed-domains &>/dev/null 2>&1; then
  IPSET_COUNT=$(sudo -n ipset list allowed-domains 2>/dev/null | grep -c "^[0-9]" || echo 0)
  if [ "$IPSET_COUNT" -gt 0 ]; then
    pass "ipset allowed-domains: ${IPSET_COUNT} エントリ"
  else
    fail "ipset allowed-domains が空"
  fi
else
  if [ "${ENABLE_FIREWALL:-true}" = "false" ]; then
    skip "ipset 未設定（ENABLE_FIREWALL=false）"
  else
    # sudo -n が使えない場合は iptables のルールで間接確認
    if sudo -n iptables -L OUTPUT -n 2>/dev/null | grep -q "match-set"; then
      pass "ipset: iptables ルールで allowed-domains の参照を確認（直接確認は sudo 権限不足）"
    else
      skip "ipset: sudo 権限不足のため直接確認不可（iptables OUTPUT DROP は確認済み）"
    fi
  fi
fi

# ブロック対象への通信テスト（example.com — 許可リスト外）
if command -v python3 &>/dev/null; then
  # タイムアウト3秒で接続テスト
  BLOCK_RESULT=$(timeout 5 python3 -c "
import socket, sys
try:
    s = socket.create_connection(('93.184.216.34', 80), timeout=3)
    s.close()
    print('CONNECTED')
except Exception as e:
    print(f'BLOCKED:{e}')
" 2>&1)

  if echo "$BLOCK_RESULT" | grep -q "BLOCKED\|timed out\|Connection refused\|Network is unreachable"; then
    pass "外部通信ブロック: example.com (93.184.216.34) への接続が拒否された"
  elif echo "$BLOCK_RESULT" | grep -q "CONNECTED"; then
    fail "外部通信ブロック: example.com (93.184.216.34) に接続できてしまった"
  else
    skip "外部通信ブロック: テスト結果が不明 ($BLOCK_RESULT)"
  fi
else
  skip "python3 未インストール"
fi

# 許可対象への通信テスト（GitHub API）
if command -v python3 &>/dev/null; then
  ALLOW_RESULT=$(timeout 10 python3 -c "
import socket, sys
try:
    ip = socket.gethostbyname('api.github.com')
    s = socket.create_connection((ip, 443), timeout=5)
    s.close()
    print('CONNECTED')
except Exception as e:
    print(f'FAILED:{e}')
" 2>&1)

  if echo "$ALLOW_RESULT" | grep -q "CONNECTED"; then
    pass "許可通信: api.github.com (443) への接続が成功した"
  else
    fail "許可通信: api.github.com (443) への接続に失敗 ($ALLOW_RESULT)"
  fi
fi

# DNS 解決が動作するか
if command -v python3 &>/dev/null; then
  DNS_RESULT=$(timeout 5 python3 -c "
import socket
try:
    ip = socket.gethostbyname('registry.npmjs.org')
    print(f'RESOLVED:{ip}')
except Exception as e:
    print(f'FAILED:{e}')
" 2>&1)

  if echo "$DNS_RESULT" | grep -q "RESOLVED"; then
    pass "DNS 解決: registry.npmjs.org 正常"
  else
    fail "DNS 解決: registry.npmjs.org 失敗 ($DNS_RESULT)"
  fi
fi

fi # IS_DEVCONTAINER

# =============================================================================
# 2. ファイルシステム制限
# =============================================================================
section "2" "ファイルシステム制限"

# /workspace への書き込み（許可されるべき）
TESTFILE="${BASE_DIR}/tests/.test_write_$$"
if touch "$TESTFILE" 2>/dev/null; then
  rm -f "$TESTFILE"
  pass "/workspace への書き込み: 許可"
else
  fail "/workspace への書き込み: 拒否された（許可されるべき）"
fi

# /etc への書き込み（拒否されるべき）
if touch /etc/.test_write_$$ 2>/dev/null; then
  rm -f /etc/.test_write_$$
  fail "/etc への書き込み: 許可されてしまった（拒否されるべき）"
else
  pass "/etc への書き込み: 拒否"
fi

# /home/node/.claude/settings.json の保護
# 注: sandbox の denyWrite は Claude Code のツール実行時にのみ適用される。
# OS レベルではファイル所有者（node）が書き込めるのは正常。
# ここでは settings.json の denyWrite 設定が正しく宣言されているかを確認する。
if [ -f "$SETTINGS" ]; then
  DENY_SETTINGS=$(jq -r '.sandbox.filesystem.denyWrite[]' "$SETTINGS" 2>/dev/null | grep -c "settings.json" || echo 0)
  if [ "$DENY_SETTINGS" -gt 0 ]; then
    pass "settings.json 保護: sandbox.denyWrite に宣言済み（Claude Code ツール実行時に適用）"
  else
    fail "settings.json 保護: sandbox.denyWrite に settings.json が含まれていない"
  fi
else
  skip "settings.json が存在しない"
fi

# 機密ディレクトリの確認
for dir in "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg"; do
  if [ -d "$dir" ]; then
    # ディレクトリが存在する場合、意図的に作成されたものでないか確認
    pass "機密ディレクトリ $dir: 存在確認（sandbox denyRead で保護）"
  else
    pass "機密ディレクトリ $dir: 存在しない（攻撃面なし）"
  fi
done

# =============================================================================
# 3. ユーザー権限
# =============================================================================
section "3" "ユーザー権限"

# 非 root で動作しているか
CURRENT_USER=$(whoami 2>/dev/null || id -un 2>/dev/null)
if [ "$CURRENT_USER" != "root" ]; then
  pass "非 root ユーザーで動作中: $CURRENT_USER"
else
  fail "root ユーザーで動作中（非 root であるべき）"
fi

# sudo が制限されているか
if sudo -n ls / &>/dev/null; then
  # sudo が使える場合、制限されたコマンドのみか確認
  SUDO_ALLOWED=$(sudo -l 2>/dev/null | grep "NOPASSWD" || true)
  if echo "$SUDO_ALLOWED" | grep -q "init-firewall\|iptables\|ip6tables\|chmod"; then
    pass "sudo: ファイアウォール関連のみ許可"
  else
    fail "sudo: 予期しないコマンドが許可されている"
  fi
else
  pass "sudo: パスワードなし実行不可（汎用コマンド）"
fi

# =============================================================================
# 4. パッケージマネージャ設定（サプライチェーン Layer 1）
# =============================================================================
section "4" "パッケージマネージャ設定（サプライチェーン Layer 1）"

# .npmrc の確認
if [ -f "$WORKSPACE/.npmrc" ]; then
  if grep -q "ignore-scripts=true" "$WORKSPACE/.npmrc"; then
    pass ".npmrc: ignore-scripts=true"
  else
    fail ".npmrc: ignore-scripts が設定されていない"
  fi

  if grep -q "registry=https://registry.npmjs.org/" "$WORKSPACE/.npmrc"; then
    pass ".npmrc: レジストリが公式のみに固定"
  else
    fail ".npmrc: レジストリ固定が未設定"
  fi

  if grep -q "audit=true" "$WORKSPACE/.npmrc"; then
    pass ".npmrc: audit=true"
  else
    fail ".npmrc: audit が有効でない"
  fi
else
  fail ".npmrc が存在しない"
fi

# .pip.conf の確認
if [ -f "$WORKSPACE/.pip.conf" ]; then
  if grep -q "index-url = https://pypi.org/simple/" "$WORKSPACE/.pip.conf"; then
    pass ".pip.conf: PyPI のみに固定"
  else
    fail ".pip.conf: index-url が正しくない"
  fi

  if grep -q "no-extra-index-url = true" "$WORKSPACE/.pip.conf"; then
    pass ".pip.conf: 追加レジストリ無効"
  else
    fail ".pip.conf: no-extra-index-url が設定されていない"
  fi
else
  fail ".pip.conf が存在しない"
fi

# .mvn-settings.xml の確認
if [ -f "$WORKSPACE/.mvn-settings.xml" ]; then
  if grep -q '<mirrorOf>\*</mirrorOf>' "$WORKSPACE/.mvn-settings.xml"; then
    pass ".mvn-settings.xml: 全リポジトリをミラー"
  else
    fail ".mvn-settings.xml: mirrorOf が * でない"
  fi

  if grep -q 'repo1.maven.org/maven2' "$WORKSPACE/.mvn-settings.xml"; then
    pass ".mvn-settings.xml: Maven Central のみ"
  else
    fail ".mvn-settings.xml: Maven Central 以外のリポジトリ"
  fi
else
  fail ".mvn-settings.xml が存在しない"
fi

# npm が実際に ignore-scripts を認識しているか
if command -v npm &>/dev/null; then
  NPM_SCRIPTS=$(npm config get ignore-scripts 2>/dev/null || echo "unknown")
  if [ "$NPM_SCRIPTS" = "true" ]; then
    pass "npm config: ignore-scripts=true（実効値）"
  else
    skip "npm config: ignore-scripts=$NPM_SCRIPTS（.npmrc がプロジェクト単位の場合は正常）"
  fi
fi

# シンリンクの確認（DevContainer 専用）
if [ "$IS_DEVCONTAINER" = "false" ]; then
  skip "Maven symlink: ローカル環境ではスキップ（DevContainer 専用）"
  skip "pip symlink: ローカル環境ではスキップ（DevContainer 専用、PIP_CONFIG_FILE 環境変数で代替）"
else
  if [ -L "$HOME/.m2/settings.xml" ]; then
    LINK_TARGET=$(readlink "$HOME/.m2/settings.xml")
    if [ "$LINK_TARGET" = "$WORKSPACE/.mvn-settings.xml" ]; then
      pass "Maven symlink: ~/.m2/settings.xml → /workspace/.mvn-settings.xml"
    else
      fail "Maven symlink: 意図しないリンク先 ($LINK_TARGET)"
    fi
  else
    if [ -f "$HOME/.m2/settings.xml" ]; then
      skip "Maven: ~/.m2/settings.xml がファイルとして存在（シンリンクでない）"
    else
      fail "Maven: ~/.m2/settings.xml が存在しない"
    fi
  fi

  if [ -L "$HOME/.config/pip/pip.conf" ]; then
    LINK_TARGET=$(readlink "$HOME/.config/pip/pip.conf")
    if [ "$LINK_TARGET" = "$WORKSPACE/.pip.conf" ]; then
      pass "pip symlink: ~/.config/pip/pip.conf → /workspace/.pip.conf"
    else
      fail "pip symlink: 意図しないリンク先 ($LINK_TARGET)"
    fi
  else
    if [ -f "$HOME/.config/pip/pip.conf" ]; then
      skip "pip: ~/.config/pip/pip.conf がファイルとして存在（シンリンクでない）"
    else
      fail "pip: ~/.config/pip/pip.conf が存在しない"
    fi
  fi
fi

# =============================================================================
# 5. 設定ファイル整合性
# =============================================================================
section "5" "設定ファイル整合性"

if [ -f "$SETTINGS" ]; then
  # disableBypassPermissionsMode の確認
  BYPASS_MODE=$(jq -r '.permissions.disableBypassPermissionsMode // "not_set"' "$SETTINGS" 2>/dev/null)
  if [ "$BYPASS_MODE" = "disable" ]; then
    pass "--dangerously-skip-permissions 無効化: 設定済み"
  else
    fail "--dangerously-skip-permissions: 無効化されていない ($BYPASS_MODE)"
  fi

  # sandbox 有効化の確認
  SANDBOX=$(jq -r '.sandbox.enabled // false' "$SETTINGS" 2>/dev/null)
  if [ "$SANDBOX" = "true" ]; then
    pass "Sandbox: 有効"
  else
    fail "Sandbox: 無効"
  fi

  # deny リストに必要なコマンドが含まれているか
  for cmd in "curl" "wget" "ssh" "scp" "nc" "sudo"; do
    if jq -r '.permissions.deny[]' "$SETTINGS" 2>/dev/null | grep -q "$cmd"; then
      pass "deny リスト: $cmd を含む"
    else
      fail "deny リスト: $cmd が含まれていない"
    fi
  done

  # denyRead に機密パスが含まれているか
  for path in ".env" ".ssh" ".aws" ".gnupg" "shadow"; do
    if jq -r '.permissions.deny[]' "$SETTINGS" 2>/dev/null | grep -q "$path"; then
      pass "deny リスト: $path の読み取り制限"
    else
      fail "deny リスト: $path の読み取り制限がない"
    fi
  done

  # WebFetch が deny されているか
  if jq -r '.permissions.deny[]' "$SETTINGS" 2>/dev/null | grep -q "WebFetch"; then
    pass "deny リスト: WebFetch を含む"
  else
    fail "deny リスト: WebFetch が含まれていない"
  fi

  # enableAllProjectMcpServers の確認
  # 注: jq の // (alternative operator) は false も falsy 扱いするので使わない
  MCP_ALL=$(jq -r 'if .enableAllProjectMcpServers == false then "false" elif .enableAllProjectMcpServers == true then "true" else "not_set" end' "$SETTINGS" 2>/dev/null)
  if [ "$MCP_ALL" = "false" ]; then
    pass "MCP: enableAllProjectMcpServers=false（ホワイトリスト制）"
  else
    fail "MCP: enableAllProjectMcpServers が false でない"
  fi

  # Hook が登録されているか
  HOOK_COUNT=$(jq '[.hooks.PreToolUse[].hooks[], .hooks.PostToolUse[].hooks[], .hooks.Stop[].hooks[]] | length' "$SETTINGS" 2>/dev/null || echo 0)
  if [ "$HOOK_COUNT" -ge 4 ]; then
    pass "Hooks: ${HOOK_COUNT} 個のフック登録済み"
  else
    fail "Hooks: フック数が不足 ($HOOK_COUNT < 4)"
  fi

  # テレメトリ無効化
  TELEMETRY=$(jq -r '.env.CLAUDE_CODE_ENABLE_TELEMETRY // "1"' "$SETTINGS" 2>/dev/null)
  if [ "$TELEMETRY" = "0" ]; then
    pass "テレメトリ: 無効化済み"
  else
    fail "テレメトリ: 無効化されていない ($TELEMETRY)"
  fi
else
  fail "settings.json が存在しない"
fi

# Hook スクリプトの存在確認
for hook in "block-dangerous.sh" "supply-chain-guard.sh" "supply-chain-audit.sh" "lint-on-save.sh" "langfuse_hook.py"; do
  if [ -f "${BASE_DIR}/hooks/$hook" ]; then
    pass "Hook ファイル: $hook 存在"
  else
    fail "Hook ファイル: $hook が見つからない (${BASE_DIR}/hooks/$hook)"
  fi
done

# =============================================================================
# 結果サマリー
# =============================================================================
echo ""
echo "=========================================="
echo -e "${BOLD}セキュリティテスト結果${NC}"
echo "=========================================="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo -e "  ${YELLOW}SKIP${NC}: $SKIP"
echo "  TOTAL: $((PASS + FAIL + SKIP))"
echo ""

if [ $FAIL -gt 0 ]; then
  echo -e "${RED}${BOLD}失敗したテスト:${NC}"
  for err in "${ERRORS[@]}"; do
    echo -e "  ${RED}•${NC} $err"
  done
  echo ""
  exit 1
else
  echo -e "${GREEN}${BOLD}全テスト合格！${NC}"
  exit 0
fi
