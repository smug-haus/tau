#!/usr/bin/env python3
"""H-003: Repeated identical tool calls.

Flag if the same tool+args hash appears 3+ times in the last 10 steps
*by the same agent session*, restricted to calls that could indicate a
genuine stuck loop (mutating or expensive operations).

Two scoping rules are load-bearing:

1. Per-session scoping. The observation log is a single global JSONL
   shared by the coordinator and every parallel sub-agent. N parallel
   agents legitimately run identical commands; counting those across the
   global window is a false positive. H-003 detects ONE agent looping,
   so it only counts calls from the current agent's session.

2. Read-only exemption. A repeated read-only *observation* command —
   polling a background task with `tail`, inspecting state with
   `git status`/`git log`, the mandated worktree position check — is an
   agent waiting or looking, not a destructive loop. Only repeated
   *mutating* or *expensive* calls (edits, `mix test`, mutating git/gh)
   are a stuck-loop signal, so read-only Bash is exempt from counting.
"""

import re

THRESHOLD = 3
SCAN_WINDOW = 10

# Read-only shell commands: inspection, polling, waiting. A repeat of any
# of these is observation, not a loop.
_READONLY_CMDS = {
    "pwd", "ls", "cat", "tail", "head", "wc", "echo", "printf", "sleep",
    "true", "false", "find", "stat", "date", "env", "which", "test", "[",
    "dirname", "basename", "realpath", "readlink", "file", "du", "df",
}

# Read-only `git` subcommands (first arg after `git`).
_READONLY_GIT = {
    "status", "log", "diff", "rev-parse", "branch", "show", "describe",
    "ls-files", "ls-remote", "rev-list", "show-ref", "for-each-ref",
    "cat-file", "blame", "shortlog", "reflog",
}


def _segment_is_readonly(seg: str) -> bool:
    """True if a single shell segment's command is read-only."""
    toks = seg.split()
    if not toks:
        return True  # empty (e.g. trailing &&) — no-op
    cmd = toks[0]
    if cmd == "git":
        return len(toks) >= 2 and toks[1] in _READONLY_GIT
    return cmd in _READONLY_CMDS


def _is_readonly_bash(obs: dict) -> bool:
    """True if a Bash observation is composed solely of read-only commands.

    Handles `&&`, `||`, `;`, and `|` chains — every segment must be
    read-only for the whole command to be exempt.
    """
    if obs.get("tool_name") != "Bash":
        return False
    summary = obs.get("tool_input_summary", "")
    segments = [s.strip() for s in re.split(r"&&|\|\||;|\|", summary)]
    segments = [s for s in segments if s]
    return bool(segments) and all(_segment_is_readonly(s) for s in segments)


def evaluate(observation: dict, window: list) -> dict:
    """Detect repeated identical tool calls within one agent's session.

    Args:
        observation: Current tool call observation. Its ``session_id``
            scopes the window — H-003 only counts repeats by this agent.
        window: Sliding window of past observations (global, all sessions).

    Returns:
        Heuristic result dict with triggered, confidence, reason.
    """
    # Scope to the current observation's session. Without this, N parallel
    # agents running identical commands aggregate in the global window and
    # trip a false positive that is not a loop.
    session_id = observation.get("session_id", "")
    scoped = [o for o in window if o.get("session_id", "") == session_id]
    recent = scoped[-SCAN_WINDOW:]

    hash_counts = {}
    # Skip read-only tools — repeated reads/searches are legitimate.
    skip_tools = {"Read", "Grep", "Glob"}
    for obs in recent:
        if obs.get("tool_name", "") in skip_tools:
            continue
        # Skip read-only Bash (polling, inspection, position checks) — a
        # repeated observation command is waiting/looking, not a loop.
        if _is_readonly_bash(obs):
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
