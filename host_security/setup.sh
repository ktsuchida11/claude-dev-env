#!/usr/bin/env bash
# =============================================================================
# host_security/setup.sh — クロスプラットフォームセキュリティセットアップ
#
# OS を自動検出し、適切なプラットフォーム固有のセットアップに dispatch する。
#
# 使い方:
#   bash host_security/setup.sh          # 対話モード
#   bash host_security/setup.sh --yes    # 全自動
#   bash host_security/setup.sh --check  # 状態確認のみ
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# プラットフォーム検出
source "$SCRIPT_DIR/platform-detect.sh"

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== ホストセキュリティセットアップ ===${NC}"
echo ""
echo -e "  プラットフォーム: ${CYAN}${PLATFORM}${NC} (${DISTRO})"
echo -e "  パッケージマネージャ: ${CYAN}${PKG_MANAGER}${NC}"
echo -e "  Init システム: ${CYAN}${INIT_SYSTEM}${NC}"
echo -e "  秘密鍵管理: ${CYAN}$(keychain_backend_name)${NC}"
echo ""

case "$PLATFORM" in
    darwin)
        MAC_SETUP="$PROJECT_ROOT/mac_security_check/setup.sh"
        if [ -f "$MAC_SETUP" ]; then
            exec bash "$MAC_SETUP" "$@"
        else
            echo -e "${RED}ERROR: mac_security_check/setup.sh が見つかりません${NC}" >&2
            exit 1
        fi
        ;;
    linux)
        LINUX_SETUP="$PROJECT_ROOT/linux_security_check/setup.sh"
        if [ -f "$LINUX_SETUP" ]; then
            exec bash "$LINUX_SETUP" "$@"
        else
            echo -e "${RED}ERROR: linux_security_check/setup.sh が見つかりません${NC}" >&2
            echo -e "${YELLOW}Linux セキュリティチェックは準備中です${NC}" >&2
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}ERROR: 未対応のプラットフォーム: $(uname -s)${NC}" >&2
        echo "対応 OS: macOS, Linux (Amazon Linux 2023, Ubuntu)" >&2
        exit 1
        ;;
esac
