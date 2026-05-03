#!/usr/bin/env python3
"""H-008: Error echo detection.

Flag if an Edit or Write operation contains text lifted from a recent Bash error.
Symptom: agent copy-pastes error messages as comments or strings instead of
fixing the underlying problem.

Detection:
  - Current observation must be an Edit or Write.
  - Scan last 5 window entries for a Bash call with exit_code != 0.
  - If any non-trivial line (≥20 chars) from stderr appears verbatim in the
    new content snippet, flag it.

Confidence: 0.7 (single match sufficient).
"""

LOOK_BACK = 5
SUBSTRING_MIN_LEN = 20


def evaluate(observation: dict, window: list) -> dict:
    """Detect error text echoed into file edits.

    Args:
        observation: Current tool call observation. Must include tool_name,
            file_path, and new_content_snippet for Edit/Write ops.
        window: Sliding window of past observations.

    Returns:
        Heuristic result dict with triggered, confidence, reason.
    """
    if observation.get("tool_name") not in ("Edit", "Write"):
        return {"heuristic_id": "H-008", "triggered": False, "confidence": 0.0, "reason": ""}

    content_snippet = observation.get("new_content_snippet", "")
    if not content_snippet:
        return {"heuristic_id": "H-008", "triggered": False, "confidence": 0.0, "reason": ""}

    content_lower = content_snippet.lower()
    recent = window[-LOOK_BACK:]

    for obs in reversed(recent):
        if obs.get("tool_name") != "Bash":
            continue
        exit_code = obs.get("exit_code")
        if exit_code is None or exit_code == 0:
            continue

        stderr_snippet = obs.get("stderr_snippet", "")
        if not stderr_snippet:
            continue

        # Check each non-trivial stderr line for verbatim inclusion
        for line in stderr_snippet.splitlines():
            stripped = line.strip()
            if len(stripped) >= SUBSTRING_MIN_LEN and stripped.lower() in content_lower:
                return {
                    "heuristic_id": "H-008",
                    "triggered": True,
                    "confidence": 0.7,
                    "reason": (
                        f"Error echo: Edit/Write to {observation.get('file_path', 'unknown')} "
                        f"contains text from a recent Bash error. "
                        f"Review whether this is intentional or an artefact."
                    ),
                }

    return {"heuristic_id": "H-008", "triggered": False, "confidence": 0.0, "reason": ""}
