#!/usr/bin/env python3
"""H-004: Test failure plateau.

Flag if test failure count is non-decreasing across 3+ consecutive test runs.
Indicates the agent is making changes that don't fix the failing tests.
"""

STALE_RUNS = 3


def evaluate(observation: dict, window: list) -> dict:
    """Detect stalled test improvement across consecutive runs.

    Args:
        observation: Current tool call observation (unused; detection is window-only).
        window: Sliding window of past observations.

    Returns:
        Heuristic result dict with triggered, confidence, reason.
    """
    test_runs = [o for o in window if o.get("test_results") is not None]

    if len(test_runs) < STALE_RUNS:
        return {"heuristic_id": "H-004", "triggered": False, "confidence": 0.0, "reason": ""}

    recent_runs = test_runs[-STALE_RUNS:]
    failure_counts = [r["test_results"].get("failures", 0) for r in recent_runs]

    # Non-decreasing across all consecutive pairs = stuck or worsening
    if all(failure_counts[i] <= failure_counts[i + 1] for i in range(len(failure_counts) - 1)):
        if failure_counts[-1] > 0:
            confidence = 0.7 if len(recent_runs) == STALE_RUNS else 0.9
            return {
                "heuristic_id": "H-004",
                "triggered": True,
                "confidence": confidence,
                "reason": (
                    f"Test failures not decreasing: {failure_counts} across "
                    f"{len(recent_runs)} consecutive runs. Step back and reconsider your approach."
                ),
            }

    return {"heuristic_id": "H-004", "triggered": False, "confidence": 0.0, "reason": ""}
