#!/usr/bin/env python3
"""H-001: Edit-undo cycle detection.

Flag if the same file's content (proxied by tool_input_hash) returns to a
previously-seen state within a 5-step look-back window.

Detection logic:
  - Current observation must be an Edit or Write operation.
  - Collect the last 5 Edit/Write ops for the same file from the window.
  - If the current hash matches any earlier hash AND there is at least one
    different hash between that match and the current op, an undo occurred.

Confidence: 0.7 on first occurrence, 0.95 on second or more.
"""

LOOK_BACK = 5


def evaluate(observation: dict, window: list) -> dict:
    """Detect edit-undo cycles on a single file.

    Args:
        observation: Current tool call observation. Must include tool_name,
            file_path, and tool_input_hash.
        window: Sliding window of past observations.

    Returns:
        Heuristic result dict with triggered, confidence, reason.
    """
    if observation.get("tool_name") not in ("Edit", "Write"):
        return {"heuristic_id": "H-001", "triggered": False, "confidence": 0.0, "reason": ""}

    current_file = observation.get("file_path", "")
    current_hash = observation.get("tool_input_hash", "")

    if not current_file or not current_hash:
        return {"heuristic_id": "H-001", "triggered": False, "confidence": 0.0, "reason": ""}

    # Collect prior Edit/Write ops for the same file (oldest → newest)
    file_ops = [
        o for o in window[-LOOK_BACK:]
        if o.get("tool_name") in ("Edit", "Write") and o.get("file_path") == current_file
    ]

    if not file_ops:
        return {"heuristic_id": "H-001", "triggered": False, "confidence": 0.0, "reason": ""}

    prior_hashes = [o.get("tool_input_hash", "") for o in file_ops]

    # Undo pattern: last op was a different hash, and current matches an earlier op.
    # This means: A → B → A (went somewhere and came back).
    last_prior_hash = prior_hashes[-1]
    if last_prior_hash == current_hash:
        # No intervening change; might be a duplicate call, not an undo.
        return {"heuristic_id": "H-001", "triggered": False, "confidence": 0.0, "reason": ""}

    if current_hash in prior_hashes:
        match_count = prior_hashes.count(current_hash)
        confidence = 0.95 if match_count >= 2 else 0.7
        return {
            "heuristic_id": "H-001",
            "triggered": True,
            "confidence": confidence,
            "reason": (
                f"Edit-undo pattern on {current_file}: content returned to a state "
                f"seen {match_count} time(s) ago. Consider a different approach."
            ),
        }

    return {"heuristic_id": "H-001", "triggered": False, "confidence": 0.0, "reason": ""}
