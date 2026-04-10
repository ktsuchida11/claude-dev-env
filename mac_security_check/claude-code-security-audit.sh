#!/usr/bin/env bash
# ============================================================
# Claude Code Security Audit Script for macOS
# Version: 1.0.0
# Date: 2026-04-10
# Author: Koji / Zui合同会社
# 
# Usage: bash claude-code-security-audit.sh [--output <path>]
# ============================================================

set -euo pipefail

# --- Configuration ---
OUTPUT_DIR="$HOME"
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    *) OUTPUT_DIR="$1"; shift ;;
  esac
done
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="${OUTPUT_DIR}/claude-code-security-report_${TIMESTAMP}.md"

# Settings file locations (macOS)
USER_SETTINGS="$HOME/.claude/settings.json"
USER_SETTINGS_LOCAL="$HOME/.claude/settings.local.json"
PROJECT_SETTINGS=".claude/settings.json"
PROJECT_SETTINGS_LOCAL=".claude/settings.local.json"
MANAGED_SETTINGS="/Library/Application Support/ClaudeCode/managed-settings.json"
CLAUDE_JSON="$HOME/.claude.json"

# Colors for terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
PASS=0
WARN=0
FAIL=0

# --- Helper Functions ---
log_pass() {
    PASS=$((PASS + 1))
    echo -e "${GREEN}✅ PASS${NC}: $1"
    echo "| ✅ PASS | $1 |" >> "$REPORT_FILE"
}

log_warn() {
    WARN=$((WARN + 1))
    echo -e "${YELLOW}⚠️  WARN${NC}: $1"
    echo "| ⚠️ WARN | $1 |" >> "$REPORT_FILE"
}

log_fail() {
    FAIL=$((FAIL + 1))
    echo -e "${RED}❌ FAIL${NC}: $1"
    echo "| ❌ FAIL | $1 |" >> "$REPORT_FILE"
}

check_json_field() {
    # $1=file, $2=jq query, returns trimmed result or "null"
    if [ -f "$1" ]; then
        jq -r "$2 // \"null\"" "$1" 2>/dev/null || echo "null"
    else
        echo "file_not_found"
    fi
}

check_deny_list_contains() {
    # $1=file, $2=pattern to search in deny array
    if [ -f "$1" ]; then
        jq -r '.permissions.deny[]? // empty' "$1" 2>/dev/null | grep -qi "$2" && return 0
    fi
    return 1
}

check_allow_list_contains() {
    # $1=file, $2=pattern to search in allow array
    if [ -f "$1" ]; then
        jq -r '.permissions.allow[]? // empty' "$1" 2>/dev/null | grep -qi "$2" && return 0
    fi
    return 1
}

# --- Begin Report ---
cat > "$REPORT_FILE" << 'HEADER'
# 🔒 Claude Code セキュリティ監査レポート

HEADER

echo "**監査日時:** $(date '+%Y-%m-%d %H:%M:%S JST')" >> "$REPORT_FILE"
echo "**実行ユーザー:** $(whoami)" >> "$REPORT_FILE"
echo "**ホスト名:** $(hostname)" >> "$REPORT_FILE"
echo "**OS:** $(sw_vers -productName 2>/dev/null || echo 'Unknown') $(sw_vers -productVersion 2>/dev/null || echo '')" >> "$REPORT_FILE"

# Claude Code version
CC_VERSION=$(claude --version 2>/dev/null || echo "not found")
echo "**Claude Code:** ${CC_VERSION}" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# ============================================================
# SECTION 1: Sandbox Status
# ============================================================
echo "## 1. サンドボックス設定" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| 判定 | チェック項目 |" >> "$REPORT_FILE"
echo "|------|-------------|" >> "$REPORT_FILE"

echo ""
echo "=== 1. サンドボックス設定 ==="

# Check if sandbox is configured in any settings file
SANDBOX_FOUND=false
for f in "$USER_SETTINGS" "$USER_SETTINGS_LOCAL" "$MANAGED_SETTINGS"; do
    if [ -f "$f" ]; then
        HAS_SANDBOX=$(jq 'has("sandbox")' "$f" 2>/dev/null || echo "false")
        if [ "$HAS_SANDBOX" = "true" ]; then
            SANDBOX_FOUND=true
            
            # Check sandbox mode
            SANDBOX_MODE=$(check_json_field "$f" '.sandbox.mode')
            if [ "$SANDBOX_MODE" != "null" ] && [ "$SANDBOX_MODE" != "file_not_found" ]; then
                log_pass "サンドボックスモード設定あり: ${SANDBOX_MODE} (in $(basename $f))"
            fi
            
            # Check allowedDomains (network isolation)
            ALLOWED_DOMAINS=$(jq '.sandbox.allowedDomains // [] | length' "$f" 2>/dev/null || echo "0")
            if [ "$ALLOWED_DOMAINS" -gt 0 ]; then
                log_pass "ネットワーク分離: allowedDomains に ${ALLOWED_DOMAINS} ドメイン設定"
            else
                log_warn "ネットワーク分離: allowedDomains 未設定（全ドメインアクセス可能）"
            fi
            
            # Check allowWrite restrictions
            ALLOW_WRITE=$(jq '.sandbox.allowWrite // [] | length' "$f" 2>/dev/null || echo "0")
            if [ "$ALLOW_WRITE" -gt 0 ]; then
                log_pass "ファイルシステム分離: allowWrite に ${ALLOW_WRITE} パス制限"
            else
                log_warn "ファイルシステム分離: allowWrite 未設定"
            fi
        fi
    fi
done

if [ "$SANDBOX_FOUND" = "false" ]; then
    log_fail "サンドボックス設定が見つかりません（/sandbox コマンドで有効化してください）"
fi

echo "" >> "$REPORT_FILE"

# ============================================================
# SECTION 2: Sensitive File Protection
# ============================================================
echo "## 2. 機密ファイル保護" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "> ⚠️ **重要:** deny ルールには既知のバグ（#6699, #6631, #8961, #27040）があり、" >> "$REPORT_FILE"
echo "> 強制力が不十分な場合があります。Hooks による補完を強く推奨します。" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| 判定 | チェック項目 |" >> "$REPORT_FILE"
echo "|------|-------------|" >> "$REPORT_FILE"

echo ""
echo "=== 2. 機密ファイル保護 ==="

# Patterns to check in deny lists
declare -a SENSITIVE_PATTERNS=(
    ".env"
    ".aws"
    ".ssh"
    "secrets"
    "credential"
    ".key"
)

declare -a SENSITIVE_LABELS=(
    ".env ファイル"
    "AWS credentials"
    "SSH鍵"
    "secrets ディレクトリ"
    "credentials ファイル"
    "秘密鍵 (.key)"
)

# Check across all settings files
ALL_SETTINGS=("$USER_SETTINGS" "$USER_SETTINGS_LOCAL" "$MANAGED_SETTINGS" "$PROJECT_SETTINGS" "$PROJECT_SETTINGS_LOCAL")

for i in "${!SENSITIVE_PATTERNS[@]}"; do
    PATTERN="${SENSITIVE_PATTERNS[$i]}"
    LABEL="${SENSITIVE_LABELS[$i]}"
    FOUND=false
    
    for f in "${ALL_SETTINGS[@]}"; do
        if check_deny_list_contains "$f" "$PATTERN"; then
            FOUND=true
            log_pass "${LABEL} の読み取りが deny に設定 ($(basename $f))"
            break
        fi
    done
    
    if [ "$FOUND" = "false" ]; then
        log_fail "${LABEL} が deny リストに未設定"
    fi
done

echo "" >> "$REPORT_FILE"

# ============================================================
# SECTION 3: Destructive Operation Restrictions
# ============================================================
echo "## 3. 破壊的操作の制限" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| 判定 | チェック項目 |" >> "$REPORT_FILE"
echo "|------|-------------|" >> "$REPORT_FILE"

echo ""
echo "=== 3. 破壊的操作の制限 ==="

# Dangerous commands to check
declare -a DANGEROUS_CMDS=(
    "rm"
    "sudo"
    "chmod"
    "git push --force"
    "curl"
    "wget"
)

declare -a DANGEROUS_LABELS=(
    "rm (ファイル削除)"
    "sudo (権限昇格)"
    "chmod (権限変更)"
    "git push --force (強制プッシュ)"
    "curl (外部通信)"
    "wget (外部通信)"
)

for i in "${!DANGEROUS_CMDS[@]}"; do
    CMD="${DANGEROUS_CMDS[$i]}"
    LABEL="${DANGEROUS_LABELS[$i]}"
    
    DENIED=false
    ALLOWED=false
    
    for f in "${ALL_SETTINGS[@]}"; do
        if check_deny_list_contains "$f" "$CMD"; then
            DENIED=true
            break
        fi
    done
    
    for f in "${ALL_SETTINGS[@]}"; do
        if check_allow_list_contains "$f" "$CMD"; then
            ALLOWED=true
            break
        fi
    done
    
    if [ "$DENIED" = "true" ]; then
        log_pass "${LABEL} が deny に設定"
    elif [ "$ALLOWED" = "true" ]; then
        log_fail "${LABEL} が allow に設定（危険）"
    else
        log_warn "${LABEL} が未設定（実行時に毎回プロンプト表示）"
    fi
done

echo "" >> "$REPORT_FILE"

# ============================================================
# SECTION 4: Permission Mode & Bypass
# ============================================================
echo "## 4. パーミッションモード" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| 判定 | チェック項目 |" >> "$REPORT_FILE"
echo "|------|-------------|" >> "$REPORT_FILE"

echo ""
echo "=== 4. パーミッションモード ==="

# Check defaultMode
for f in "${ALL_SETTINGS[@]}"; do
    if [ -f "$f" ]; then
        DEFAULT_MODE=$(check_json_field "$f" '.permissions.defaultMode')
        if [ "$DEFAULT_MODE" != "null" ] && [ "$DEFAULT_MODE" != "file_not_found" ]; then
            if [ "$DEFAULT_MODE" = "bypassPermissions" ]; then
                log_fail "defaultMode が bypassPermissions（全権限をスキップ） in $(basename $f)"
            elif [ "$DEFAULT_MODE" = "acceptEdits" ]; then
                log_warn "defaultMode が acceptEdits（編集を自動承認） in $(basename $f)"
            else
                log_pass "defaultMode: ${DEFAULT_MODE} in $(basename $f)"
            fi
        fi
    fi
done

# Check disableBypassPermissionsMode
BYPASS_DISABLED=false
for f in "${ALL_SETTINGS[@]}"; do
    if [ -f "$f" ]; then
        DISABLE_BYPASS=$(check_json_field "$f" '.permissions.disableBypassPermissionsMode')
        if [ "$DISABLE_BYPASS" = "disable" ]; then
            BYPASS_DISABLED=true
            log_pass "bypassPermissions モードが無効化されている ($(basename $f))"
            break
        fi
    fi
done

if [ "$BYPASS_DISABLED" = "false" ]; then
    log_warn "disableBypassPermissionsMode が未設定（--dangerously-skip-permissions が使用可能）"
fi

echo "" >> "$REPORT_FILE"

# ============================================================
# SECTION 5: Hooks (PreToolUse) - Most Reliable Defense
# ============================================================
echo "## 5. Hooks（最も信頼性の高い防御層）" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| 判定 | チェック項目 |" >> "$REPORT_FILE"
echo "|------|-------------|" >> "$REPORT_FILE"

echo ""
echo "=== 5. Hooks ==="

HOOKS_FOUND=false
for f in "${ALL_SETTINGS[@]}"; do
    if [ -f "$f" ]; then
        HAS_HOOKS=$(jq 'has("hooks")' "$f" 2>/dev/null || echo "false")
        if [ "$HAS_HOOKS" = "true" ]; then
            HOOKS_FOUND=true
            
            # Check PreToolUse hooks
            PRE_TOOL=$(jq '.hooks.PreToolUse // [] | length' "$f" 2>/dev/null || echo "0")
            if [ "$PRE_TOOL" -gt 0 ]; then
                log_pass "PreToolUse フック: ${PRE_TOOL} 個設定 ($(basename $f))"
            fi
            
            # Check PostToolUse hooks
            POST_TOOL=$(jq '.hooks.PostToolUse // [] | length' "$f" 2>/dev/null || echo "0")
            if [ "$POST_TOOL" -gt 0 ]; then
                log_pass "PostToolUse フック: ${POST_TOOL} 個設定 ($(basename $f))"
            fi
        fi
    fi
done

if [ "$HOOKS_FOUND" = "false" ]; then
    log_fail "Hooks 未設定（deny ルールのバグを補完する最も信頼性の高い防御層です）"
fi

# Check for custom hook scripts in ~/.claude/hooks/
if [ -d "$HOME/.claude/hooks" ]; then
    HOOK_COUNT=$(find "$HOME/.claude/hooks" -type f \( -name "*.py" -o -name "*.sh" \) 2>/dev/null | wc -l | tr -d ' ')
    if [ "$HOOK_COUNT" -gt 0 ]; then
        log_pass "カスタムフックスクリプト: ${HOOK_COUNT} 個検出 (~/.claude/hooks/)"
    else
        log_warn "~/.claude/hooks/ は存在するがスクリプトなし"
    fi
else
    log_warn "~/.claude/hooks/ ディレクトリ未作成（自前フックの配置先）"
fi

echo "" >> "$REPORT_FILE"

# ============================================================
# SECTION 6: MCP Server Security
# ============================================================
echo "## 6. MCP サーバー設定" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| 判定 | チェック項目 |" >> "$REPORT_FILE"
echo "|------|-------------|" >> "$REPORT_FILE"

echo ""
echo "=== 6. MCP サーバー ==="

MCP_FILE=".mcp.json"
if [ -f "$MCP_FILE" ]; then
    MCP_COUNT=$(jq '.mcpServers | length' "$MCP_FILE" 2>/dev/null || echo "0")
    log_warn "MCP サーバー ${MCP_COUNT} 個設定あり（各サーバーの信頼性を確認してください）"
    
    # List MCP servers
    echo "" >> "$REPORT_FILE"
    echo "設定済み MCP サーバー:" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    jq -r '.mcpServers | keys[]' "$MCP_FILE" 2>/dev/null | while read srv; do
        echo "- \`${srv}\`" >> "$REPORT_FILE"
    done
elif [ -f "$CLAUDE_JSON" ]; then
    MCP_USER=$(jq '.mcpServers // {} | length' "$CLAUDE_JSON" 2>/dev/null || echo "0")
    if [ "$MCP_USER" -gt 0 ]; then
        log_warn "~/.claude.json に MCP サーバー ${MCP_USER} 個（ユーザースコープ）"
    else
        log_pass "MCP サーバー未設定 or 最小構成"
    fi
else
    log_pass "MCP 設定ファイルなし"
fi

echo "" >> "$REPORT_FILE"

# ============================================================
# SECTION 7: Environment & Runtime Checks
# ============================================================
echo "## 7. 実行環境" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| 判定 | チェック項目 |" >> "$REPORT_FILE"
echo "|------|-------------|" >> "$REPORT_FILE"

echo ""
echo "=== 7. 実行環境 ==="

# Running as root?
if [ "$(whoami)" = "root" ]; then
    log_fail "root ユーザーで実行中（非推奨）"
else
    log_pass "非 root ユーザーで実行中: $(whoami)"
fi

# SIP (System Integrity Protection) status
SIP_STATUS=$(csrutil status 2>/dev/null || echo "unknown")
if echo "$SIP_STATUS" | grep -q "enabled"; then
    log_pass "macOS SIP: 有効"
else
    log_warn "macOS SIP: 無効または不明 (${SIP_STATUS})"
fi

# Check cleanupPeriodDays
for f in "${ALL_SETTINGS[@]}"; do
    if [ -f "$f" ]; then
        CLEANUP=$(check_json_field "$f" '.cleanupPeriodDays')
        if [ "$CLEANUP" != "null" ] && [ "$CLEANUP" != "file_not_found" ]; then
            if [ "$CLEANUP" -le 14 ]; then
                log_pass "トランスクリプト保持期間: ${CLEANUP} 日 ($(basename $f))"
            else
                log_warn "トランスクリプト保持期間: ${CLEANUP} 日（7-14日推奨）"
            fi
        fi
    fi
done

# Check CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
for f in "${ALL_SETTINGS[@]}"; do
    if [ -f "$f" ]; then
        DISABLE_TRAFFIC=$(jq -r '.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC // "null"' "$f" 2>/dev/null || echo "null")
        if [ "$DISABLE_TRAFFIC" = "1" ]; then
            log_pass "非必須トラフィック無効化: ON ($(basename $f))"
            break
        fi
    fi
done

echo "" >> "$REPORT_FILE"

# ============================================================
# SECTION 8: Settings File Inventory
# ============================================================
echo "## 8. 設定ファイル一覧" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| ファイル | 状態 |" >> "$REPORT_FILE"
echo "|----------|------|" >> "$REPORT_FILE"

for f in "$USER_SETTINGS" "$USER_SETTINGS_LOCAL" "$PROJECT_SETTINGS" "$PROJECT_SETTINGS_LOCAL" "$MANAGED_SETTINGS" "$CLAUDE_JSON" ".mcp.json"; do
    if [ -f "$f" ]; then
        echo "| \`$f\` | ✅ 存在 |" >> "$REPORT_FILE"
    else
        echo "| \`$f\` | — なし |" >> "$REPORT_FILE"
    fi
done

echo "" >> "$REPORT_FILE"

# ============================================================
# Summary
# ============================================================
TOTAL=$((PASS + WARN + FAIL))
SCORE=0
if [ "$TOTAL" -gt 0 ]; then
    SCORE=$(( (PASS * 100) / TOTAL ))
fi

# Grade
if [ "$FAIL" -eq 0 ] && [ "$WARN" -le 2 ]; then
    GRADE="A"
    GRADE_EMOJI="🟢"
elif [ "$FAIL" -le 2 ]; then
    GRADE="B"
    GRADE_EMOJI="🟡"
elif [ "$FAIL" -le 5 ]; then
    GRADE="C"
    GRADE_EMOJI="🟠"
else
    GRADE="D"
    GRADE_EMOJI="🔴"
fi

# Insert summary at the top after header
SUMMARY=$(cat << EOF

## 📊 サマリー

| 指標 | 値 |
|------|-----|
| 総合グレード | ${GRADE_EMOJI} **${GRADE}** |
| スコア | ${SCORE}% (${PASS}/${TOTAL}) |
| ✅ PASS | ${PASS} |
| ⚠️ WARN | ${WARN} |
| ❌ FAIL | ${FAIL} |

---

EOF
)

# Insert summary after the header metadata
TEMP_FILE=$(mktemp)
awk -v summary="$SUMMARY" '
    /^## 1\./ { print summary }
    { print }
' "$REPORT_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$REPORT_FILE"

# ============================================================
# Recommendations
# ============================================================
cat >> "$REPORT_FILE" << 'RECO'
---

## 🛡️ 推奨アクション

### 最優先（deny バグへの対策）

deny ルールには複数の既知バグがあり、設定しても無視される場合があります。
**Hooks (PreToolUse) が現時点で最も信頼性の高い防御層**です。

```json
// ~/.claude/settings.json - hooks 設定例
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/hooks/block-sensitive-files.py"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/hooks/block-dangerous-commands.py"
          }
        ]
      }
    ]
  }
}
```

### 推奨設定（多層防御）

```json
{
  "env": {
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": 1
  },
  "cleanupPeriodDays": 7,
  "permissions": {
    "disableBypassPermissionsMode": "disable",
    "deny": [
      "Read(**/.env)", "Read(**/.env.*)",
      "Read(**/.aws/**)", "Read(**/.ssh/**)",
      "Read(**/secrets/**)", "Read(**/*.key)", "Read(**/*.pem)",
      "Bash(rm:*)", "Bash(sudo:*)", "Bash(su:*)",
      "Bash(chmod:*)", "Bash(curl:*)", "Bash(wget:*)",
      "Bash(ssh:*)"
    ]
  }
}
```

### サンドボックス有効化

Claude Code 内で `/sandbox` を実行し、モードを選択してください。
macOS では Seatbelt によるカーネルレベルの分離が適用されます。

### ⚠️ サードパーティ製セキュリティツールについて

Claude Code 周辺では非公式ツールを装ったマルウェア配布が確認されています。
セキュリティ関連ツールは以下の基準で導入を判断してください:

- Anthropic 公式（`anthropics` org 配下）かどうか
- GitHub スター数・コントリビューター数・監査履歴
- フック経由で任意コードを実行させる仕組みのリスク評価
- **自前で PreToolUse フックを書く方が安全**です（同梱の block-sensitive-files.py 参照）

RECO

# Add reference links
cat >> "$REPORT_FILE" << 'REFS'
---

## 📚 参考リンク

- [Claude Code Settings 公式ドキュメント](https://code.claude.com/docs/en/settings)
- [Claude Code Sandboxing 公式](https://code.claude.com/docs/en/sandboxing)
- [Claude Code Security (Anthropic Engineering)](https://www.anthropic.com/engineering/claude-code-sandboxing)
- [deny バグ #6699](https://github.com/anthropics/claude-code/issues/6699)
- [deny バグ #27040](https://github.com/anthropics/claude-code/issues/27040)
- [Anthropic sandbox-runtime (公式)](https://github.com/anthropic-experimental/sandbox-runtime)
REFS

echo ""
echo "============================================"
echo -e "  総合グレード: ${GRADE_EMOJI} ${GRADE}"
echo -e "  ${GREEN}PASS: ${PASS}${NC}  ${YELLOW}WARN: ${WARN}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo "  レポート: ${REPORT_FILE}"
echo "============================================"
