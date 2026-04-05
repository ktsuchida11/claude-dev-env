#!/usr/bin/env bash
# supply-chain-audit.sh — PostToolUse Hook for package install commands
# パッケージインストール後に脆弱性監査を自動実行する
#
# Layer 3: Post-Install 脆弱性スキャン
# - npm audit (Node.js)
# - pip-audit (Python)
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

AUDIT_TYPE=""

# npm install の検出
if echo "$COMMAND" | grep -qE '^\s*npm\s+(install|i|add)\b'; then
  AUDIT_TYPE="npm"
fi

# pip install / uv の検出
if echo "$COMMAND" | grep -qE '^\s*(pip|pip3)\s+install\b'; then
  AUDIT_TYPE="pip"
fi
if echo "$COMMAND" | grep -qE '^\s*uv\s+(pip\s+install|add)\b'; then
  AUDIT_TYPE="pip"
fi

# パッケージインストールでなければスルー
if [ -z "$AUDIT_TYPE" ]; then
  exit 0
fi

# === 監査実行 ===

echo "" >&2
echo "Supply Chain Audit - Post-Install" >&2
echo "==========================================" >&2

if [ "$AUDIT_TYPE" = "npm" ]; then
  # npm audit の実行
  # package-lock.json がある場所を探す
  AUDIT_DIR="."
  if echo "$COMMAND" | grep -qP '(?<=cd\s)[^\s;&]+'; then
    AUDIT_DIR=$(echo "$COMMAND" | grep -oP '(?<=cd\s)[^\s;&]+' | head -1)
  fi

  if [ -f "$AUDIT_DIR/package-lock.json" ]; then
    echo "  Running: npm audit (in $AUDIT_DIR)" >&2
    AUDIT_RESULT=$(cd "$AUDIT_DIR" && npm audit --json 2>/dev/null || true)

    if [ -n "$AUDIT_RESULT" ]; then
      VULN_TOTAL=$(echo "$AUDIT_RESULT" | jq -r '.metadata.vulnerabilities // {} | to_entries | map(.value) | add // 0' 2>/dev/null || echo "?")
      VULN_HIGH=$(echo "$AUDIT_RESULT" | jq -r '.metadata.vulnerabilities.high // 0' 2>/dev/null || echo "0")
      VULN_CRITICAL=$(echo "$AUDIT_RESULT" | jq -r '.metadata.vulnerabilities.critical // 0' 2>/dev/null || echo "0")

      if [ "$VULN_TOTAL" = "0" ] || [ "$VULN_TOTAL" = "?" ]; then
        echo "  [OK] npm audit: 脆弱性は検出されませんでした" >&2
      else
        echo "  [WARN] npm audit: $VULN_TOTAL 件の脆弱性が検出されました" >&2
        if [ "$VULN_CRITICAL" != "0" ]; then
          echo "  [ALERT] Critical: $VULN_CRITICAL 件" >&2
        fi
        if [ "$VULN_HIGH" != "0" ]; then
          echo "  [ALERT] High: $VULN_HIGH 件" >&2
        fi
        echo "  詳細: npm audit を実行してください" >&2
      fi
    else
      echo "  [INFO] npm audit の実行をスキップしました" >&2
    fi
  else
    echo "  [INFO] package-lock.json なし — npm audit をスキップ" >&2
  fi
fi

if [ "$AUDIT_TYPE" = "pip" ]; then
  # pip-audit の実行
  if command -v pip-audit &>/dev/null; then
    echo "  Running: pip-audit" >&2
    AUDIT_RESULT=$(pip-audit --format=json 2>/dev/null || true)

    if [ -n "$AUDIT_RESULT" ]; then
      VULN_COUNT=$(echo "$AUDIT_RESULT" | jq -r 'length // 0' 2>/dev/null || echo "?")

      if [ "$VULN_COUNT" = "0" ] || [ "$VULN_COUNT" = "?" ]; then
        echo "  [OK] pip-audit: 脆弱性は検出されませんでした" >&2
      else
        echo "  [WARN] pip-audit: $VULN_COUNT 件の脆弱性が検出されました" >&2
        # 上位3件を表示
        echo "$AUDIT_RESULT" | jq -r '.[0:3][] | "    - \(.name) \(.version): \(.vulns[0].id // "unknown") — \(.vulns[0].description // "N/A")[0:80]"' 2>/dev/null >&2 || true
        if [ "$VULN_COUNT" -gt 3 ] 2>/dev/null; then
          echo "    ... 他 $((VULN_COUNT - 3)) 件" >&2
        fi
        echo "  詳細: pip-audit を実行してください" >&2
      fi
    else
      echo "  [INFO] pip-audit の実行をスキップしました" >&2
    fi
  else
    echo "  [INFO] pip-audit 未インストール — スキップ" >&2
    echo "         pip install pip-audit でインストールできます" >&2
  fi
fi

echo "==========================================" >&2

# 監査は情報提供のみ。インストール自体はブロックしない
exit 0
