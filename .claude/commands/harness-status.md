---
name: harness-status
description: >
  Show current harness status: observation count, active kill signals,
  solution tree state, and recent heuristic triggers.
allowed-tools: Read, Bash, Grep, Glob
---

Read and display current harness runtime state. Report each section in order.

---

## 1. Observation Log

Check `.claude/logs/observations.jsonl`:
- If absent: report "No observations recorded."
- If present: count total lines (one observation per line). Show the last 5 entries. For each, display: tool name and summary field. Example format:
  ```
  Total observations: 42
  Last 5:
    [38] Bash — exit code 1, repeated failure
    [39] Bash — exit code 1, repeated failure
    [40] Read — file not found
    [41] Glob — 0 matches
    [42] Bash — exit code 1, repeated failure
  ```

## 2. Kill Signal

Read `.claude/logs/kill-signal.json`:
- If absent: report "No active kill signal."
- If present and `active` is false: report "Kill signal present but inactive."
- If present and `active` is true: report the `reason`, `heuristic_id`, and `timestamp` fields. Example:
  ```
  ACTIVE KILL SIGNAL
    heuristic: H-003
    reason: Repeated failure loop detected (3 consecutive failures)
    timestamp: 2026-02-22T14:32:01Z
  ```

## 3. Solution Tree

Read `.claude/logs/solution-tree.json`:
- If absent: report "No active solution tree."
- If present: display `task_id`, `attempt_count`, `current_strategy`, and `last_outcome`. Example:
  ```
  Solution tree: task-abc123
    attempts: 3
    strategy: refine
    last outcome: FAIL — off-by-one in loop bounds
  ```

## 4. Recent Heuristic Triggers

Grep `.claude/logs/observations.jsonl` for the last 20 observations that contain a `heuristic_id` field or a `confidence` value above 0.0. List each: heuristic ID, confidence, and trigger reason. Example:
  ```
  Recent triggers (last 20 observations):
    H-003 @ 0.85 — repeated bash failure
    H-001 @ 0.60 — large write without prior read
  ```
  If none found: report "No heuristic triggers in last 20 observations."

---

Format the full output as a clean status report with section headers. Keep it scannable.
