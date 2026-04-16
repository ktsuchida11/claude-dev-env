#!/usr/bin/env bash
# ============================================================
# Claude Code Security Audit Script for Linux
# Version: 1.0.0
# Date: 2026-04-11
# Author: 
# macOS 版 (claude-code-security-audit.sh) をベースに、
# Linux 固有の 3 箇所のみ変更したラッパー。
#
# 変更点:
#   1. MANAGED_SETTINGS パスを Linux 用に変更
#   2. sw_vers → /etc/os-release
#   3. csrutil → getenforce (SELinux)
#
# Usage: bash claude-code-security-audit-linux.sh [--output <path>]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAC_AUDIT="$PROJECT_ROOT/mac_security_check/claude-code-security-audit.sh"

if [ ! -f "$MAC_AUDIT" ]; then
    echo "ERROR: mac_security_check/claude-code-security-audit.sh が見つかりません" >&2
    exit 1
fi

# macOS 版のスクリプトをコピーし、Linux 固有の差分を適用して実行
TMPSCRIPT="${TMPDIR:-/tmp}/claude-audit-linux-$$.sh"
trap 'rm -f "$TMPSCRIPT"' EXIT

cp "$MAC_AUDIT" "$TMPSCRIPT"

# 1. MANAGED_SETTINGS パス変更
sed -i'' -e 's|MANAGED_SETTINGS="/Library/Application Support/ClaudeCode/managed-settings.json"|MANAGED_SETTINGS="/etc/claude-code/managed-settings.json"|' "$TMPSCRIPT"

# 2. sw_vers → /etc/os-release
sed -i'' -e 's|$(sw_vers -productName 2>/dev/null || echo '"'"'Unknown'"'"')|$(cat /etc/os-release 2>/dev/null \| grep "^PRETTY_NAME=" \| cut -d= -f2 \| tr -d '"'"'"'"'"' || echo '"'"'Linux'"'"')|' "$TMPSCRIPT"
sed -i'' -e 's| $(sw_vers -productVersion 2>/dev/null || echo '"'"''"'"')||' "$TMPSCRIPT"

# 3. csrutil → getenforce (SELinux)
sed -i'' -e 's|SIP_STATUS=$(csrutil status 2>/dev/null || echo "unknown")|SIP_STATUS=$(getenforce 2>/dev/null || echo "unknown")|' "$TMPSCRIPT"
sed -i'' -e 's|macOS SIP: 有効|SELinux: Enforcing|' "$TMPSCRIPT"
sed -i'' -e 's|macOS SIP: 無効または不明|SELinux: 非 Enforcing|' "$TMPSCRIPT"
sed -i'' -e 's|echo "$SIP_STATUS" | grep -q "enabled"|echo "$SIP_STATUS" | grep -qi "enforcing"|' "$TMPSCRIPT"

# 実行
bash "$TMPSCRIPT" "$@"
