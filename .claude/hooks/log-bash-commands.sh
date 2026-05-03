#!/usr/bin/env bash
# PostToolUse hook: log bash commands to audit trail
# Receives JSON on stdin: { "tool_name": "Bash", "tool_input": { "command": "..." }, "tool_response": { ... } }
# Always exits 0 — this is observational, never blocks.

set -euo pipefail

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // "unknown"' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
mkdir -p "$LOG_DIR"

echo "${TIMESTAMP} [${TOOL_NAME}] ${COMMAND}" >> "$LOG_DIR/bash-commands.log"

exit 0
