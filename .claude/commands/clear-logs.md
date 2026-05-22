---
name: clear-logs
description: >
  Reset harness runtime state: clear observations, kill signals, and
  solution tree. Use between tasks or to recover from a stuck state.
allowed-tools: Bash
---

Reset harness runtime state by removing log files.

---

## Step 1: Clear Log Files

Remove each file if it exists:

1. `.claude/logs/observations.jsonl`
2. `.claude/logs/kill-signal.json`

Use `rm -f` for each. Do not fail if a file is absent.

## Step 2: Confirm

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
