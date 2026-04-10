#!/bin/bash
# setup-mcp.sh - Idempotently merge MCP server settings into ~/.claude/.claude.json
set -euo pipefail

TEMPLATE="/etc/claude-mcp/mcp-servers.json"
SETTINGS_FILE="/home/node/.claude/.claude.json"
PROJECT_PATH="/workspace"

if [ ! -f "${TEMPLATE}" ]; then
  echo "MCP template not found at ${TEMPLATE}, skipping MCP setup."
  exit 0
fi

# テンプレートが有効な JSON であることを検証
if ! jq empty "${TEMPLATE}" 2>/dev/null; then
  echo "ERROR: MCP template ${TEMPLATE} is not valid JSON. Aborting."
  exit 1
fi

if [ ! -f "${SETTINGS_FILE}" ]; then
  # No existing settings - create initial structure
  jq -n --arg project "${PROJECT_PATH}" \
    --slurpfile servers "${TEMPLATE}" \
    '{ projects: { ($project): { mcpServers: $servers[0] } } }' \
    > "${SETTINGS_FILE}" || {
      echo "ERROR: Failed to create ${SETTINGS_FILE}. jq command failed."
      exit 1
    }
  echo "Created ${SETTINGS_FILE} with MCP servers."
else
  # 既存設定が有効な JSON であることを検証
  if ! jq empty "${SETTINGS_FILE}" 2>/dev/null; then
    echo "ERROR: ${SETTINGS_FILE} is not valid JSON. Aborting to prevent data loss."
    exit 1
  fi

  # バックアップを作成
  BACKUP="${SETTINGS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${SETTINGS_FILE}" "${BACKUP}"

  # Merge: template servers as base, user's existing entries take priority
  MERGED=$(jq --arg project "${PROJECT_PATH}" \
    --slurpfile servers "${TEMPLATE}" '
    .projects[$project].mcpServers = (
      $servers[0] * (.projects[$project].mcpServers // {})
    )
  ' "${SETTINGS_FILE}") || {
    echo "ERROR: jq merge failed. Settings file preserved. Backup: ${BACKUP}"
    exit 1
  }

  # マージ結果が空でないことを検証
  if [ -z "${MERGED}" ]; then
    echo "ERROR: jq produced empty output. Settings file preserved. Backup: ${BACKUP}"
    exit 1
  fi

  # マージ結果が有効な JSON であることを検証
  if ! echo "${MERGED}" | jq empty 2>/dev/null; then
    echo "ERROR: jq produced invalid JSON. Settings file preserved. Backup: ${BACKUP}"
    exit 1
  fi

  echo "${MERGED}" > "${SETTINGS_FILE}"
  echo "Merged MCP settings into ${SETTINGS_FILE}."
fi
