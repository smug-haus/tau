#!/usr/bin/env python3
"""
SubagentStart hook: inject solution tree context into new implementer subagent.

Reads SubagentStart event JSON from stdin. Only injects context when:
  - event.agent_type == "implementer"
  - solution tree exists with at least one prior attempt

Returns JSON:
  {"additionalContext": "<preamble>"} — if prior attempts exist for implementer
  {}                                   — otherwise (first attempt, wrong agent type, no tree)

Environment:
  HARNESS_PROJECT_ROOT — root of the harness project (preferred)
  CLAUDE_PROJECT_DIR   — fallback
  "."                  — last resort

Python stdlib only. No external dependencies.
"""

import json
import os
import sys


STRATEGY_EXPLANATIONS = {
    "refine": (
        "REFINE: The previous approach was on the right track. "
        "Improve it incrementally — fix the specific failure points without "
        "abandoning the overall direction."
    ),
    "pivot": (
        "PIVOT: Previous approaches failed to make progress. "
        "Choose a fundamentally different approach. Do not reuse the same "
        "algorithm, library choices, or structural patterns that were tried before."
    ),
    "meta-restart": (
        "META-RESTART: All previous approaches have been exhausted. "
        "Start completely fresh. Re-read the task description from scratch "
        "and form an independent plan before writing any code."
    ),
}

KILL_REASON_AVOIDANCES = {
    "H-003": "Do not repeat identical operations expecting different results.",
    "H-004": "Do not continue an approach that has plateaued — change strategy.",
    "H-001": "Do not loop over the same sequence of tool calls.",
    "H-002": "Do not re-read the same files without taking action on their content.",
    "H-005": "Do not ignore test output — act on failures rather than re-running.",
}


def project_root() -> str:
    return (
        os.environ.get("HARNESS_PROJECT_ROOT")
        or os.environ.get("CLAUDE_PROJECT_DIR")
        or "."
    )


def extract_avoidance(kill_reason: str) -> str:
    if not kill_reason:
        return ""
    for code, instruction in KILL_REASON_AVOIDANCES.items():
        if code in kill_reason:
            return instruction
    return f"Killed for: {kill_reason} — avoid repeating the same pattern."


def build_preamble(tree: dict) -> str:
    attempts = tree.get("attempts", [])
    if not attempts:
        return ""

    task_description = tree.get("task_description", "(no description)")
    current_strategy = tree.get("current_strategy", "refine")
    strategy_text = STRATEGY_EXPLANATIONS.get(
        current_strategy,
        f"Strategy: {current_strategy}"
    )

    lines = [
        "=== CONTEXT FROM PREVIOUS ATTEMPTS ===",
        "",
        f"Task: {task_description}",
        "",
        "--- Previous Attempts ---",
    ]

    for attempt in attempts:
        attempt_id = attempt.get("attempt_id", "?")
        approach = attempt.get("approach_summary", "(no summary)")
        outcome = attempt.get("outcome", "unknown")
        kill_reason = attempt.get("kill_reason", "")
        key_decisions = attempt.get("key_decisions", [])

        lines.append(f"Attempt {attempt_id}: {approach}")
        lines.append(f"  Outcome: {outcome}")
        if kill_reason:
            lines.append(f"  Killed: {kill_reason}")
        if key_decisions:
            lines.append(f"  Key decisions: {', '.join(key_decisions)}")

    lines.append("")
    lines.append("--- What to AVOID ---")

    seen_avoidances: set = set()

    # Explicit avoidance list from solution tree (coordinator-curated)
    for item in tree.get("avoidance_list", []):
        if item and item not in seen_avoidances:
            seen_avoidances.add(item)
            lines.append(f"- {item}")

    # Dynamic avoidances from kill reasons
    for attempt in attempts:
        kill_reason = attempt.get("kill_reason", "")
        avoidance = extract_avoidance(kill_reason)
        if avoidance and avoidance not in seen_avoidances:
            seen_avoidances.add(avoidance)
            lines.append(f"- {avoidance}")

    # Avoidances from failed approaches
    for attempt in attempts:
        approach = attempt.get("approach_summary", "")
        key_decisions = attempt.get("key_decisions", [])
        if approach:
            lines.append(f"- Do NOT use: {approach}")
        for decision in key_decisions:
            lines.append(f"  Avoid: {decision}")

    lines.append("")
    lines.append("--- Current Strategy ---")
    lines.append(strategy_text)
    lines.append("")
    lines.append("=== END CONTEXT ===")

    return "\n".join(lines)


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print("{}")
        return

    # Only inject for implementer agents
    if event.get("agent_type") != "implementer":
        print("{}")
        return

    tree_path = os.path.join(
        project_root(), ".claude", "logs", "solution-tree.json"
    )

    if not os.path.exists(tree_path):
        print("{}")
        return

    try:
        with open(tree_path, "r", encoding="utf-8") as f:
            tree = json.load(f)
    except (json.JSONDecodeError, OSError):
        print("{}")
        return

    if not tree.get("attempts"):
        print("{}")
        return

    preamble = build_preamble(tree)
    if not preamble:
        print("{}")
        return

    print(json.dumps({"additionalContext": preamble}))


if __name__ == "__main__":
    main()
