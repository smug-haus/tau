#!/usr/bin/env python3
"""H-003: Repeated identical tool calls.

Flag if same tool+args hash appears 3+ times in last 10 steps.
Indicates the agent is stuck in a loop without varying its approach.
"""

THRESHOLD = 3
SCAN_WINDOW = 10


def evaluate(observation: dict, window: list) -> dict:
    """Detect repeated identical tool calls within a sliding window.

    Args:
        observation: Current tool call observation (unused; detection is window-only).
        window: Sliding window of past observations.

    Returns:
        Heuristic result dict with triggered, confidence, reason.
    """
    recent = window[-SCAN_WINDOW:]
    hash_counts = {}
    # Skip read-only tools — repeated reads are often legitimate
    skip_tools = {"Read", "Grep", "Glob"}
    for obs in recent:
        if obs.get("tool_name", "") in skip_tools:
            continue
        h = obs.get("tool_input_hash", "")
        if h:
            hash_counts[h] = hash_counts.get(h, 0) + 1

    for h, count in hash_counts.items():
        if count >= THRESHOLD:
            tool = next(
                (o["tool_name"] for o in recent if o.get("tool_input_hash") == h),
                "unknown",
            )
            summary = next(
                (o["tool_input_summary"] for o in recent if o.get("tool_input_hash") == h),
                "",
            )
            return {
                "heuristic_id": "H-003",
                "triggered": True,
                "confidence": 0.85,
                "reason": (
                    f"Repeated identical tool call: {tool} ({summary}), "
                    f"{count} times in last {SCAN_WINDOW} steps. Try a different approach."
                ),
            }

    return {"heuristic_id": "H-003", "triggered": False, "confidence": 0.0, "reason": ""}
