#!/usr/bin/env python3
"""H-005: Context burn without progress.

Proxy metric for token consumption. Counts tool calls since the last
observable progress event. Progress is defined as:
  - Any Edit or Write operation (file modified), or
  - A test run where failure count decreased from a prior run.

Threshold: 50+ consecutive tool calls with no measurable progress.
Soft signal: confidence capped at 0.6.
"""

PROGRESS_THRESHOLD = 50
CONFIDENCE_CAP = 0.6
CONFIDENCE_BASE = 0.3


def evaluate(observation: dict, window: list) -> dict:
    """Detect extended periods with no measurable progress.

    Args:
        observation: Current tool call observation.
        window: Sliding window of past observations.

    Returns:
        Heuristic result dict with triggered, confidence, reason.
    """
    last_progress_idx = None
    last_failure_count = None

    for i, obs in enumerate(window):
        tool = obs.get("tool_name", "")

        if tool in ("Edit", "Write"):
            last_progress_idx = i
            continue

        if tool == "Bash":
            test_results = obs.get("test_results")
            if test_results is not None:
                failures = test_results.get("failures", 0)
                if last_failure_count is None:
                    last_failure_count = failures
                elif failures < last_failure_count:
                    # Test improved — counts as progress
                    last_progress_idx = i
                    last_failure_count = failures
                else:
                    last_failure_count = failures

    if last_progress_idx is None:
        no_progress_count = len(window) + 1  # +1 for current observation
    else:
        no_progress_count = len(window) - last_progress_idx  # +1 current, -1 for 0-index cancel

    if no_progress_count >= PROGRESS_THRESHOLD:
        excess = no_progress_count - PROGRESS_THRESHOLD
        confidence = min(CONFIDENCE_CAP, CONFIDENCE_BASE + excess * 0.01)
        return {
            "heuristic_id": "H-005",
            "triggered": True,
            "confidence": confidence,
            "reason": (
                f"Context burn: {no_progress_count} tool calls with no measurable progress "
                f"(no files modified, no test improvement). Consider pausing and summarising."
            ),
        }

    return {"heuristic_id": "H-005", "triggered": False, "confidence": 0.0, "reason": ""}
