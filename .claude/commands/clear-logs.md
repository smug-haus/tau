---
name: clear-logs
description: >
  Reset harness runtime state: clear observations, kill signals, and
  solution tree. Use between tasks or to recover from a stuck state.
allowed-tools: Bash
---

Reset harness runtime state by removing log files. Follow these steps in order.

---

## Step 1: Check for In-Progress Work

Read `.claude/logs/solution-tree.json`. If it exists and contains an `attempt_count` greater than 0, **stop and ask the user to confirm** before proceeding. The solution tree records attempt history — clearing it is irreversible.

Example prompt:
```
Solution tree found: task-abc123 with 3 attempts recorded.
Clearing will permanently discard this history. Proceed? (yes/no)
```

If the solution tree is absent or has `attempt_count: 0`, proceed without prompting.

## Step 2: Clear Log Files

Remove each file if it exists:

1. `.claude/logs/observations.jsonl`
2. `.claude/logs/kill-signal.json`
3. `.claude/logs/solution-tree.json`

Use `rm -f` for each. Do not fail if a file is absent.

## Step 3: Confirm

Report which files were removed and which were absent. Example:

```
Cleared:
  observations.jsonl — removed
  kill-signal.json — removed
  solution-tree.json — absent (nothing to clear)

Harness state reset. Ready for next task.
```

---

After clearing, the harness starts fresh on the next tool call. Any active kill cascade is lifted.
