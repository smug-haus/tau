# Retry Decision Framework — Worked Examples

Four scenarios showing how to apply the refine/pivot/give-up decision.

---

## Example 1: Tactical failure → Refine

**Context**: Attempt 1 to implement the heuristic monitor hook.

**Kill reason**:
```
H-003: Repeated identical call. Tool Bash called with identical arguments 3 times in last 8 steps. Agent appears stuck.
```

**Investigation**: The agent repeatedly ran `python .claude/hooks/heuristic_monitor.py` and received `ModuleNotFoundError: No module named 'utils'`. The import path was wrong.

**Classification**: Tactical. Specific, identifiable cause. One file, one import path.

**Decision**: Refine.

**Solution tree entry**:
```json
{
  "attempt_id": 1,
  "approach_summary": "Implemented heuristic monitor as PostToolUse hook. Correct structure but used wrong relative import path for shared utilities.",
  "outcome": "killed",
  "kill_reason": "H-003: Repeated identical Bash call (import error loop)",
  "files_modified": [".claude/hooks/heuristic_monitor.py"],
  "key_decisions": ["Used relative import", "Placed utils in hooks/utils.py"]
}
```

**Next attempt preamble addition**:
> Previous attempt failed because `utils` was imported as a module (`from utils import ...`) but the hook runs from the project root, not from the hooks directory. Use absolute import path relative to project root: `from .claude.hooks.utils import ...`, or restructure to use stdlib only and inline the utility functions.

---

## Example 2: Strategic failure → Pivot

**Context**: Attempt 2 to implement the solution tree update logic.

**Kill reason**:
```
H-001: Edit-undo cycle detected on .claude/logs/solution_tree.json. File returned to previous hash (seen 4 steps ago).
```

**Investigation**: The agent was trying to update the solution tree by reading the JSON, merging in the new attempt record, and writing it back. It kept oscillating because its merge logic was corrupting the `attempts` array — it was treating the array as a dict.

**Classification**: This is not a simple bug. The agent has already attempted the same approach twice (attempts 1 and 2 both tried JSON read-merge-write) and keeps producing the same structural corruption. The approach has a fundamental flaw.

**Decision**: Pivot.

**Solution tree entry**:
```json
{
  "attempt_id": 2,
  "approach_summary": "Tried to update solution tree via read-merge-write pattern. Merge logic corrupted attempts array by treating it as a dict.",
  "outcome": "killed",
  "kill_reason": "H-001: Edit-undo cycle on solution_tree.json",
  "files_modified": [".claude/hooks/update_solution_tree.py", ".claude/logs/solution_tree.json"],
  "key_decisions": ["Used json.loads + dict.update for merge", "Wrote entire file on each update"]
}
```

**Pivot rationale**: The read-merge-write pattern has failed twice with the same structural error. The next approach should either: (a) use append-only writes with a final merge step, or (b) treat each attempt record as a separate file and assemble them only when needed.

---

## Example 3: Compound failure → Pivot

**Context**: Attempt 3 to implement context injection.

**Kill reasons** (two heuristics simultaneously):
```
H-004: Test failure plateau. Failure count: [3, 3, 3]. No improvement across 3 runs.
H-005: Context burn. 62 tool calls with no writes or test improvement.
```

**Investigation**: The agent was trying to understand how the SubagentStart hook receives context and where to inject the preamble. It read 15+ files over 62 tool calls without writing anything or improving tests. Simultaneously, the 3 tests for context injection had been failing at the same count throughout.

**Classification**: Two heuristics triggered simultaneously. The agent is both stuck (not acting) and not converging (tests flat). This is compound confusion.

**Decision**: Pivot (mandatory when 2+ heuristics at ≥0.6).

**Pivot rationale**: The agent doesn't understand the injection mechanism well enough to act. Rather than having the next agent explore from scratch, provide a directed briefing: explain exactly how SubagentStart hooks work and exactly where the preamble should be inserted. The next agent should not need to discover this through exploration.

---

## Example 4: Evaluation failure → Refine

**Context**: Attempt 1 to implement the kill cascade.

**Outcome**: `failed_evaluation` (tests pass, reviewer found issues).

**Evaluation finding**:
> The kill signal file is written correctly, but the coordinator's reader does not handle the case where the file is written mid-read (partial write). Under load, the coordinator may read a truncated JSON file and crash rather than retry.

**Classification**: Tests pass, so the happy path works. The issue is a specific edge case: partial write during read. This is a targeted, identifiable fix.

**Decision**: Refine.

**Solution tree entry**:
```json
{
  "attempt_id": 1,
  "approach_summary": "Implemented kill cascade: hook writes sentinel file, coordinator reads it after subagent exits. Basic flow works.",
  "outcome": "failed_evaluation",
  "kill_reason": null,
  "evaluation": "Coordinator does not handle partial write on kill signal file. json.loads may fail on truncated content.",
  "files_modified": [
    ".claude/hooks/heuristic_monitor.py",
    ".claude/coordinator/read_kill_signal.py"
  ],
  "key_decisions": ["Used atomic write via temp file + rename", "Did not add retry on read failure"]
}
```

**Next attempt preamble addition**:
> Previous attempt's coordinator reader crashes on truncated kill signal files (partial writes). Fix: wrap `json.loads` in try/except, retry read up to 3 times with 50ms delay before giving up. The write side already uses atomic temp-file rename, so the window is small but not zero.
