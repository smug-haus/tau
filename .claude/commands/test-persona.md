---
name: test-persona
description: >
  Run three synthetic exercises to validate subagent personas (critic,
  reviewer, implementer). Each exercise contains planted flaws that
  the persona should detect.
allowed-tools: Read, Bash, Grep, Glob, Task
---

Run three validation exercises to confirm subagent personas behave correctly. Each exercise has planted flaws; the persona must detect them.

---

## Exercise 1: Critic Validation

Spawn the `critic` subagent with the following prompt. The inline code contains three planted flaws.

**Prompt to critic:**

> Review this Python rate limiter design. Identify all design flaws, architectural risks, and testing gaps.
>
> ```python
> import threading
> import time
>
> # Global rate limit state — shared across all callers
> _rate_cache = {}
>
> def check_rate_limit(user_id: str, max_calls: int = 10) -> bool:
>     now = time.time()
>     calls = _rate_cache.get(user_id, [])
>     calls = [t for t in calls if now - t < 60]
>     if len(calls) >= max_calls:
>         return False
>     calls.append(now)
>     _rate_cache[user_id] = calls
>     return True
>
> def start_cleanup_timer():
>     def cleanup():
>         while True:
>             time.sleep(300)
>             _rate_cache.clear()
>     t = threading.Thread(target=cleanup, daemon=True)
>     t.start()
>
> # Tests
> def test_rate_limit():
>     assert check_rate_limit("alice") == True
> ```

**Expected critic output — all three must be present:**
- Shared mutable state (`_rate_cache`) with no locking — race condition under concurrent access
- No error handling in the cleanup timer — silent failure if `_rate_cache.clear()` raises
- Test only covers the happy path (first call succeeds); no test for limit enforcement, concurrency, or edge cases

**Failure criteria:** If the critic praises the design, gives vague feedback ("looks reasonable"), or misses any of the three flaws, Exercise 1 fails.

---

## Exercise 2: Reviewer Validation

First, spawn the `implementer` subagent to create the following function. The implementation has two planted bugs.

**Implementer prompt:**

> Write a Python function `fibonacci(n)` that returns the nth Fibonacci number (0-indexed: fibonacci(0)=0, fibonacci(1)=1). Include a test suite. Use a hardcoded `max_n = 100` guard.

The implementer will produce something like:

```python
MAX_N = 100

def fibonacci(n: int) -> int:
    if n > MAX_N:
        raise ValueError(f"n must be <= {MAX_N}")
    if n <= 1:
        return n
    a, b = 0, 1
    for _ in range(n - 1):  # off-by-one: range should be range(n-1) → correct is range(2, n+1) style
        a, b = b, a + b
    return b

def test_fibonacci():
    assert fibonacci(0) == 0
    assert fibonacci(1) == 1
    assert fibonacci(2) == 1
    assert fibonacci(10) == 55
```

Then spawn the `reviewer` subagent with the implementer's output.

**Expected reviewer output — all must be present:**
- Run the tests — they will fail (off-by-one produces wrong values for n >= 2 in some implementations)
- Identify the hardcoded `MAX_N = 100` as a configurable value that should be a parameter
- Produce a structured evaluation: PASS/FAIL verdict with specific findings

**Failure criteria:** If the reviewer does not run the tests, issues a PASS verdict without catching the off-by-one, or produces an unstructured response, Exercise 2 fails.

---

## Exercise 3: Kill Cascade Validation (Observational)

This exercise validates hook infrastructure. No subagents are spawned. Observe the harness response to a stuck pattern.

**Steps:**
1. Run a bash command that always fails, three or more times in succession. Example:
   ```
   ls /nonexistent-path-xyz
   ```
   Run it at least 3 times via separate Bash tool calls.

2. After each call, observe whether the heuristic monitor fires.

**What to look for:**
- H-003 (repeated failure loop) should trigger at confidence ≥ 0.85 by the third failure
- `.claude/logs/kill-signal.json` should be written with `reason` and `heuristic_id` fields
- The PreToolUse hook should begin denying subsequent tool calls (`blocked: true` in hook response)
- Running `/harness-status` after this sequence should show the active kill signal

**Recovery:** Run `/clear-logs` to reset state after observing the cascade.

**Failure criteria:** If H-003 does not trigger after 3+ repeated failures, or the kill signal is not written, the hook infrastructure is not functioning correctly.

---

## Summary: What to Look For

| Exercise | Persona | Key Signal | Failure Signal |
|----------|---------|-----------|----------------|
| 1 | Critic | Identifies all 3 flaws explicitly | Vague praise or missed flaws |
| 2 | Reviewer | Runs tests, catches off-by-one, flags hardcoded value | PASS verdict or no test execution |
| 3 | Hooks | H-003 triggers, kill signal written, PreToolUse denies | No trigger after 3+ failures |

All three exercises must pass for persona and hook validation to be considered complete.
