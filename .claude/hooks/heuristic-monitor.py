#!/usr/bin/env python3
"""
PostToolUse heuristic monitor — production implementation.

Receives tool call JSON on stdin. Builds an observation record, appends
to JSONL log, runs all registered heuristics against the sliding window,
and returns feedback via the escalation ladder.

Exit 0 for advisory/block feedback (JSON on stdout).
Exit 2 for critical alerts (stderr only, mutually exclusive with stdout).
"""

import json
import os
import sys

# Ensure the heuristics package is importable
_HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
if _HOOK_DIR not in sys.path:
    sys.path.insert(0, _HOOK_DIR)

from heuristics.common import (
    get_obs_path,
    get_project_root,
    load_window,
    make_observation,
)

WINDOW_SIZE = 20


def main():
    # ── Read event from stdin ──────────────────────────────────────────
    try:
        raw = sys.stdin.read()
        event = json.loads(raw)
    except (json.JSONDecodeError, Exception):
        return  # Malformed input — fail open

    # ── Build and append observation ───────────────────────────────────
    obs_path = get_obs_path()
    os.makedirs(obs_path.parent, exist_ok=True)

    observation = make_observation(event)

    with open(obs_path, "a") as f:
        f.write(json.dumps(observation) + "\n")

    # ── Load sliding window ────────────────────────────────────────────
    window = load_window(WINDOW_SIZE, obs_path)

    # ── Discover and run heuristics ────────────────────────────────────
    heuristics = _load_heuristics()
    alerts = []

    for heuristic_mod in heuristics:
        try:
            result = heuristic_mod.evaluate(observation, window)
            if result.get("triggered"):
                alerts.append(result)
        except Exception as e:
            print(f"[MONITOR] Heuristic error: {e}", file=sys.stderr)

    if not alerts:
        return

    # ── Escalation ladder ──────────────────────────────────────────────
    # Sort by confidence descending — escalate based on highest
    alerts.sort(key=lambda a: a.get("confidence", 0), reverse=True)
    top = alerts[0]
    top_confidence = top.get("confidence", 0)

    # Combined trigger: 2+ heuristics at >=0.6 → escalate to kill
    multi_trigger = len([a for a in alerts if a.get("confidence", 0) >= 0.6]) >= 2

    reason = _build_reason(alerts)

    if top_confidence >= 0.9 or (multi_trigger and top_confidence >= 0.6):
        # CRITICAL: Write kill signal + exit 2
        _write_kill_signal(top, event, reason)
        print(reason, file=sys.stderr)
        sys.exit(2)

    elif top_confidence >= 0.8:
        # HIGH: Write kill signal + decision: block
        _write_kill_signal(top, event, reason)
        output = {
            "decision": "block",
            "reason": reason,
        }
        print(json.dumps(output))
        return

    elif top_confidence >= 0.6:
        # MEDIUM: decision: block (forced acknowledgment, no kill signal)
        output = {
            "decision": "block",
            "reason": reason,
        }
        print(json.dumps(output))
        return

    else:
        # LOW (0.4-0.6): additionalContext (soft nudge)
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": reason,
            }
        }
        print(json.dumps(output))
        return


def _build_reason(alerts):
    """Build a combined reason string from all triggered alerts."""
    parts = []
    for alert in alerts:
        hid = alert.get("heuristic_id", "?")
        conf = alert.get("confidence", 0)
        reason = alert.get("reason", "")
        parts.append(f"[{hid}] (confidence: {conf:.2f}) {reason}")
    return "\n".join(parts)


def _write_kill_signal(top_alert, event, reason):
    """Write kill signal file for PreToolUse deny cascade."""
    root = get_project_root()
    signal_path = root / ".claude" / "logs" / "kill-signal.json"
    os.makedirs(signal_path.parent, exist_ok=True)

    from datetime import datetime, timezone

    signal = {
        "active": True,
        "session_id": event.get("session_id", ""),
        "reason": reason,
        "heuristic_id": top_alert.get("heuristic_id", ""),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "allowed_tools": ["Read", "Grep", "Glob"],
    }

    try:
        with open(signal_path, "w") as f:
            json.dump(signal, f, indent=2)
    except OSError:
        pass  # Best effort — don't crash the hook


def _load_heuristics():
    """Load all H-xxx and D-xxx heuristic modules."""
    modules = []

    # H-xxx: known behavioral heuristics
    h_modules = [
        "heuristics.h001_edit_undo",
        "heuristics.h003_repeated_calls",
        "heuristics.h004_test_plateau",
        "heuristics.h005_context_burn",
        "heuristics.h008_error_echo",
    ]

    import importlib

    for mod_name in h_modules:
        try:
            mod = importlib.import_module(mod_name)
            if hasattr(mod, "evaluate"):
                modules.append(mod)
        except ImportError as e:
            print(f"[MONITOR] Failed to load {mod_name}: {e}", file=sys.stderr)

    # D-xxx: project-specific design heuristics (auto-discovered)
    design_dir = os.path.join(_HOOK_DIR, "heuristics", "design")
    if os.path.isdir(design_dir):
        for fname in sorted(os.listdir(design_dir)):
            if fname.endswith(".py") and fname != "__init__.py":
                mod_name = f"heuristics.design.{fname[:-3]}"
                try:
                    mod = importlib.import_module(mod_name)
                    if hasattr(mod, "evaluate"):
                        modules.append(mod)
                except (ImportError, Exception) as e:
                    print(f"[MONITOR] Failed to load D-xxx {mod_name}: {e}", file=sys.stderr)

    return modules


if __name__ == "__main__":
    main()
