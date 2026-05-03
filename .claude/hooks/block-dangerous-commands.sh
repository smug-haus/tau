#!/usr/bin/env bash
# PreToolUse hook: block dangerous bash commands
# Receives JSON on stdin: { "tool_name": "Bash", "tool_input": { "command": "..." } }
# Exit 0 = allow, Exit 2 = block (reason on stdout)

set -euo pipefail

COMMAND=$(jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Patterns that should never run
BLOCKED_PATTERNS=(
  'rm -rf /'
  'rm -rf /*'
  'rm -rf ~'
  'mkfs\.'
  'dd if=.* of=/dev/'
  ':(){:|:&};:'
  'chmod -R 777 /'
  'curl .* \| .*sh'
  'wget .* \| .*sh'
  'pip install(?!.*--break-system-packages)'
  'pip3 install(?!.*--break-system-packages)'
  'sudo '
  'apt install'
  'apt-get install'
  'brew install'
  'npm install -g'
  'git push .* main'
  'git push .* master'
  'git push --force'
  'git reset --hard'
)

for pattern in "${BLOCKED_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qEi "$pattern"; then
    echo "Blocked: command matches dangerous pattern '$pattern'"
    exit 2
  fi
done

exit 0
