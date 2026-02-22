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

if [ ! -f "${SETTINGS_FILE}" ]; then
  # No existing settings - create initial structure
  jq -n --arg project "${PROJECT_PATH}" \
    --slurpfile servers "${TEMPLATE}" \
    '{ projects: { ($project): { mcpServers: $servers[0] } } }' \
    > "${SETTINGS_FILE}"
  echo "Created ${SETTINGS_FILE} with MCP servers."
else
  # Merge: template servers as base, user's existing entries take priority
  MERGED=$(jq --arg project "${PROJECT_PATH}" \
    --slurpfile servers "${TEMPLATE}" '
    .projects[$project].mcpServers = (
      $servers[0] * (.projects[$project].mcpServers // {})
    )
  ' "${SETTINGS_FILE}")
  echo "${MERGED}" > "${SETTINGS_FILE}"
  echo "Merged MCP settings into ${SETTINGS_FILE}."
fi
