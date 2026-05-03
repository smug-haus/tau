#!/usr/bin/env python3
"""
PreToolUse hook: deny cascade when kill signal is active.

Reads {HARNESS_PROJECT_ROOT}/.claude/logs/kill-signal.json.
If the signal is active and the requested tool is not in allowed_tools, denies
the tool call with a termination reason.

Fails open on any error (missing file, malformed JSON, env issues) — the hook
must never block legitimate work due to an internal fault.

Exit codes:
    0 — always (allow or deny is communicated via JSON output, not exit code)
"""

import json
import os
import sys


def project_root() -> str:
    return (
        os.environ.get("HARNESS_PROJECT_ROOT")
        or os.environ.get("CLAUDE_PROJECT_DIR")
        or "."
    )


def allow() -> None:
    print("{}")
    sys.exit(0)


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as e:
        print(f"ERROR: invalid JSON on stdin: {e}", file=sys.stderr)
        allow()

    kill_signal_path = os.path.join(
        project_root(), ".claude", "logs", "kill-signal.json"
    )

    if not os.path.exists(kill_signal_path):
        allow()

    try:
        with open(kill_signal_path) as f:
            signal = json.load(f)
    except (json.JSONDecodeError, OSError):
        allow()

    if not signal.get("active", False):
        allow()

    tool_name = event.get("tool_name", "")
    allowed_tools = signal.get("allowed_tools", [])

    if tool_name in allowed_tools:
        allow()

    reason = signal.get("reason", "Kill signal active")
    heuristic_id = signal.get("heuristic_id", "UNKNOWN")

    deny_reason = (
        f"TERMINATED: {reason}. "
        f"Heuristic {heuristic_id} fired. "
        f"Summarize what you tried and stop. "
        f"Only {', '.join(allowed_tools)} tools are available."
    )

    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": deny_reason,
        }
    }
    print(json.dumps(output))
    sys.exit(0)


if __name__ == "__main__":
    main()
