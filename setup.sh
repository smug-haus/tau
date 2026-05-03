#!/usr/bin/env bash
# setup.sh — Claude Agent Harness one-time setup
# Safe to run multiple times (idempotent).

set -euo pipefail

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
printf '\n'
printf '================================================\n'
printf '  Claude Agent Harness — Setup\n'
printf '================================================\n'
printf '\n'

# ---------------------------------------------------------------------------
# OS check
# ---------------------------------------------------------------------------
case "${OSTYPE:-}" in
  linux*|darwin*)
    ;;
  msys*|cygwin*|win*)
    printf 'NOTE: Native Windows is not supported.\n'
    printf '      Please run this script inside WSL (Windows Subsystem for Linux).\n'
    printf '\n'
    ;;
  *)
    printf 'NOTE: Unrecognised OS type "%s".\n' "${OSTYPE:-unknown}"
    printf '      If you are on Windows, please use WSL.\n'
    printf '      Continuing anyway — your mileage may vary.\n'
    printf '\n'
    ;;
esac

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
printf '[ Prerequisites ]\n'
PREREQS_OK=1

check_tool() {
  local tool="$1"
  local hint="$2"
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  %-10s  OK (%s)\n' "$tool" "$(command -v "$tool")"
  else
    printf '  %-10s  MISSING — %s\n' "$tool" "$hint"
    PREREQS_OK=0
  fi
}

check_tool python3 "install via your package manager (apt install python3 / brew install python3)"
check_tool jq     "install via your package manager (apt install jq / brew install jq)"

if [ "$PREREQS_OK" -eq 0 ]; then
  printf '\n  WARNING: one or more prerequisites are missing.\n'
  printf '  Hook scripts may not function correctly until they are installed.\n'
fi
printf '\n'

# ---------------------------------------------------------------------------
# Stack detection
# ---------------------------------------------------------------------------
printf '[ Stack Detection ]\n'

DETECTED_STACKS=()

[ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ] && DETECTED_STACKS+=("Python")
[ -f package.json ]                                                   && DETECTED_STACKS+=("Node.js")
[ -f go.mod ]                                                         && DETECTED_STACKS+=("Go")
[ -f Cargo.toml ]                                                     && DETECTED_STACKS+=("Rust")

SELECTED_STACK=""

if [ "${#DETECTED_STACKS[@]}" -eq 0 ]; then
  printf '  No known stack detected.\n'
  SELECTED_STACK="Other / manual"

elif [ "${#DETECTED_STACKS[@]}" -eq 1 ]; then
  SELECTED_STACK="${DETECTED_STACKS[0]}"
  printf '  Detected: %s\n' "$SELECTED_STACK"

else
  printf '  Multiple stacks detected:\n'
  for i in "${!DETECTED_STACKS[@]}"; do
    printf '    %d) %s\n' "$((i + 1))" "${DETECTED_STACKS[$i]}"
  done
  printf '    %d) Other / manual\n' "$((${#DETECTED_STACKS[@]} + 1))"
  printf '\n'

  while true; do
    printf '  Select your primary stack [1-%d]: ' "$((${#DETECTED_STACKS[@]} + 1))"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [ "$choice" -ge 1 ] && [ "$choice" -le "${#DETECTED_STACKS[@]}" ]; then
        SELECTED_STACK="${DETECTED_STACKS[$((choice - 1))]}"
        break
      elif [ "$choice" -eq "$((${#DETECTED_STACKS[@]} + 1))" ]; then
        SELECTED_STACK="Other / manual"
        break
      fi
    fi
    printf '  Invalid selection. Try again.\n'
  done
fi

printf '\n'
printf '  Stack: %s\n' "$SELECTED_STACK"

# Informational note on test parser (Phase 2 wires this up)
case "$SELECTED_STACK" in
  Python)
    printf '  Test parser: pytest output parser (configured in Phase 2)\n'
    ;;
  Node.js)
    printf '  Test parser: Jest/Mocha output parser (configured in Phase 2)\n'
    ;;
  Go)
    printf '  Test parser: go test output parser (configured in Phase 2)\n'
    ;;
  Rust)
    printf '  Test parser: cargo test output parser (configured in Phase 2)\n'
    ;;
  *)
    printf '  Test parser: manual configuration required (see docs/architecture.md)\n'
    ;;
esac
printf '\n'

# ---------------------------------------------------------------------------
# Sandbox opt-in
# ---------------------------------------------------------------------------
printf '[ Sandbox Mode ]\n'
printf '  Sandbox mode restricts agent file-system access to the project directory.\n'
printf '  Recommended for untrusted or exploratory work.\n'
printf '\n'
printf '  Enable sandbox mode? [y/N]: '
read -r sandbox_choice

SANDBOX_ENABLED=0
case "${sandbox_choice,,}" in   # lowercase
  y|yes)
    SANDBOX_ENABLED=1
    printf '  Sandbox mode: ENABLED\n'
    printf '  NOTE: Update .claude/settings.json to enforce sandbox constraints.\n'
    ;;
  *)
    printf '  Sandbox mode: disabled\n'
    ;;
esac
printf '\n'

# ---------------------------------------------------------------------------
# File setup
# ---------------------------------------------------------------------------
printf '[ File Setup ]\n'

# Create logs directory
if [ -d .claude/logs ]; then
  printf '  .claude/logs/        already exists\n'
else
  mkdir -p .claude/logs
  printf '  .claude/logs/        created\n'
fi

# Copy settings.local.json from template if available
TEMPLATE=".claude/settings.local.json.template"
TARGET=".claude/settings.local.json"

if [ -f "$TARGET" ]; then
  printf '  %-38s already exists (not overwritten)\n' "$TARGET"
elif [ -f "$TEMPLATE" ]; then
  cp "$TEMPLATE" "$TARGET"
  printf '  %-38s created from template\n' "$TARGET"
else
  printf '  %-38s no template found; skipping\n' "$TARGET"
fi

# Make hook scripts executable
HOOKS_DIR=".claude/hooks"
if [ -d "$HOOKS_DIR" ]; then
  HOOK_COUNT=0
  while IFS= read -r -d '' f; do
    chmod +x "$f"
    HOOK_COUNT=$((HOOK_COUNT + 1))
  done < <(find "$HOOKS_DIR" -type f \( -name '*.py' -o -name '*.sh' \) -print0)
  printf '  chmod +x              %d hook script(s) in %s\n' "$HOOK_COUNT" "$HOOKS_DIR"
else
  printf '  %s not found; skipping chmod\n' "$HOOKS_DIR"
fi

printf '\n'

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------
printf '[ Next Steps ]\n'
printf '\n'
printf '  1. Edit CLAUDE.md — add your project description, key commands,\n'
printf '     and any constraints specific to your codebase.\n'
printf '\n'
printf '  2. Review .claude/settings.json — check permissions and hook\n'
printf '     configuration match your workflow.\n'
if [ "$SANDBOX_ENABLED" -eq 1 ]; then
  printf '     (Sandbox mode selected — ensure sandbox constraints are set.)\n'
fi
printf '\n'
printf '  3. Verify setup:\n'
printf '       claude /test-persona\n'
printf '\n'
printf '  4. (Phase 2) Configure test parser for %s in .claude/settings.json.\n' "$SELECTED_STACK"
printf '\n'
printf '================================================\n'
printf '  Setup complete.\n'
printf '================================================\n'
printf '\n'
