# Solution Tree Schema

The solution tree is a JSON file at `.claude/logs/solution_tree.json`. It is the single source of truth for retry decisions. The SubagentStart hook reads it to generate the preamble for each new attempt.

---

## Schema

```json
{
  "task_id": "string — unique identifier for this task, used in log file names",
  "task_description": "string — original task as given to the coordinator, unchanged",
  "attempts": [
    {
      "attempt_id": "number — 1-indexed, increments on each attempt",
      "approach_summary": "string — 1-2 sentences describing the strategy used",
      "outcome": "string — one of: killed | completed | failed_evaluation",
      "kill_reason": "string | null — exact kill reason from heuristic monitor, or null",
      "evaluation": "string | null — key finding from code review if failed_evaluation, or null",
      "duration_seconds": "number — wall clock time from subagent start to termination",
      "tokens_consumed": "number — approximate tokens used by the subagent",
      "files_modified": ["string — list of file paths changed during this attempt"],
      "key_decisions": ["string — 2-3 decisions that constrained the approach"]
    }
  ],
  "current_strategy": "string — one of: refine | pivot",
  "avoidance_list": ["string — things explicitly tried and known not to work"],
  "max_attempts": "number — hard limit, default 5"
}
```

---

## Complete Example

A realistic three-attempt scenario: two failed attempts (tactical then strategic) followed by a successful third.

```json
{
  "task_id": "impl-heuristic-monitor-001",
  "task_description": "Implement the heuristic monitor as a PostToolUse hook. The hook receives tool call context on stdin as JSON, evaluates all active heuristics, and returns a JSON response controlling whether to block or kill. Must complete in <100ms. No pip dependencies — stdlib only.",
  "attempts": [
    {
      "attempt_id": 1,
      "approach_summary": "Implemented monitor with H-001, H-003, H-004 in a single script. Used hash-based file tracking and sliding window for repeated calls. Script structure was correct but used a relative import for shared hash utilities.",
      "outcome": "killed",
      "kill_reason": "H-003: Repeated identical Bash call (3 times in 8 steps). Agent stuck on ModuleNotFoundError for relative import.",
      "evaluation": null,
      "duration_seconds": 187,
      "tokens_consumed": 14200,
      "files_modified": [
        ".claude/hooks/heuristic_monitor.py",
        ".claude/hooks/utils/hashing.py"
      ],
      "key_decisions": [
        "Separated hash utilities into utils/hashing.py",
        "Used relative import: from utils.hashing import content_hash",
        "Stored file hash history in module-level dict"
      ]
    },
    {
      "attempt_id": 2,
      "approach_summary": "Inlined hash utilities to eliminate import issue. Added H-005 (context burn) and H-008 (error echo) to the single-file implementation. All heuristics working in isolation. Failed on integration: session state was not persisted between hook invocations because module-level dict resets each call.",
      "outcome": "failed_evaluation",
      "kill_reason": null,
      "evaluation": "Module-level dict for file hash history resets on every hook invocation. Hooks run as subprocess — no persistent in-process state. H-001 and H-003 cannot function without persistent state across calls.",
      "duration_seconds": 342,
      "tokens_consumed": 22800,
      "files_modified": [
        ".claude/hooks/heuristic_monitor.py"
      ],
      "key_decisions": [
        "Inlined all utilities to avoid import issues",
        "Used module-level dict for per-file hash history",
        "Did not read architecture notes on state persistence"
      ]
    },
    {
      "attempt_id": 3,
      "approach_summary": "Rewrote to use filesystem-backed state in .claude/logs/heuristic_state.json. Each hook invocation reads state at start, updates it, writes it back atomically. All 5 heuristics implemented. Tests pass.",
      "outcome": "completed",
      "kill_reason": null,
      "evaluation": null,
      "duration_seconds": 298,
      "tokens_consumed": 19400,
      "files_modified": [
        ".claude/hooks/heuristic_monitor.py",
        ".claude/logs/heuristic_state.json"
      ],
      "key_decisions": [
        "Filesystem-backed state via heuristic_state.json",
        "Atomic write using temp file + os.rename",
        "State keyed by worktree path to support concurrent sessions"
      ]
    }
  ],
  "current_strategy": "refine",
  "avoidance_list": [
    "Relative imports from within the hooks directory — scripts run from project root",
    "Module-level dict for persistent state — hooks run as subprocess, no in-process persistence",
    "json.load directly on state file without try/except — file may be absent on first run"
  ],
  "max_attempts": 5
}
```

---

## Usage Notes

**Writing**: The coordinator writes to the solution tree after each attempt terminates, before launching the next attempt. Never write during a live attempt.

**Reading**: The SubagentStart hook reads the solution tree and injects a preamble. It reads `attempts[-3:]` (last 3 attempts) and `avoidance_list` to construct the preamble. Older attempts are available but not injected by default.

**Atomic writes**: Use temp file + `os.rename` to write the solution tree. Partial writes cause hook crashes.

**Token budget**: Keep `approach_summary` under 100 tokens, `evaluation` under 150 tokens, `key_decisions` items under 50 tokens each. The SubagentStart hook injects up to 3 attempt summaries; if each is 500 tokens, the preamble costs 1500 tokens of the subagent's context budget.
