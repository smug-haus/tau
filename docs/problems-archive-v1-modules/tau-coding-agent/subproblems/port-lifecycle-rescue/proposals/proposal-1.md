---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Guard-only — eliminate the catch by relying on Port.info/1 nil match alone

## Approach

Replace the `try/catch` block in `close_port/1` with a bare guard-clause pattern: match
on `Port.info(port)` returning `nil` (port already closed) in the guard, and call
`Port.close/1` unconditionally in the single remaining clause. Remove the `Port.info/1`
pre-check entirely. Any `ArgumentError` from `Port.close/1` on a just-died port propagates
to the caller; callers that want silent-on-closed behaviour add an explicit match at their
call site.

```elixir
defp close_port(nil), do: :ok

defp close_port(port) when is_port(port) do
  Port.close(port)
  :ok
end

defp close_port(_), do: :ok
```

Call sites (`port_done/1` and `port_next/2` cancel branch) keep their `:ok` return
expectation; if the port was already closed — which is unlikely given single-owner
semantics — the `ArgumentError` bubbles to those callers, making the event visible.

## Rationale

The complecting hypothesis is that liveness testing is woven with close: the function
guards, then catches the very thing it just guarded against. This proposal severs the
weave by eliminating both halves of the tangle simultaneously — no guard, no catch.
`Port.close/1` on a live port is the common case; on a dead port it raises exactly one
specific error (`ArgumentError`) that identifies the situation precisely. Allowing the
error to propagate means unexpected errors are no longer indistinguishable from "already
closed", satisfying the acceptance criterion directly. The change is behaviour-correcting
(previously unexpected errors were swallowed; now they propagate) but the functional
contract — close the port, return `:ok` on success — is unchanged for the common path.

## Sketch

Diff (conceptual):

```diff
-  defp close_port(port) when is_port(port) do
-    try do
-      if Port.info(port) do
-        Port.close(port)
-      end
-    catch
-      _, _ -> :ok
-    end
-    :ok
-  end
+  defp close_port(port) when is_port(port) do
+    Port.close(port)
+    :ok
+  end
```

File: `lib/tau/coding_agents/claude_code.ex` — change is 9 lines removed, 3 lines added.
No new modules, no new types. No call-site changes unless a caller wishes to explicitly
handle `ArgumentError`.

## Tradeoffs

### Strengths

- Smallest possible diff: one function, three clauses collapse to two effective lines.
- Eliminates both TOCTOU and silent swallow in a single move — fully satisfies the
  acceptance criterion.
- No new abstractions; no new dependencies.
- Reasoning is trivially checkable: `Port.close/1` either succeeds or raises `ArgumentError`
  and the error is no longer hidden.
- Consistent with OTP non-negotiable rule 7: let it crash.

### Weaknesses

- `port_done/1` and the cancel branch in `port_next/2` now receive an `ArgumentError` if a
  port was closed by an outside actor between stream start and cleanup. Both callers
  currently ignore the return and the crash would propagate up the stream pipeline — this
  may be acceptable (OTP supervision handles it) but it changes observable behaviour.
- Does not provide a structured tagged-tuple return — callers cannot pattern-match `:ok |
  {:error, :already_closed}` without also catching `ArgumentError`.
- If either call site is inside a `Stream.resource/3` `after_fun`, an uncaught
  `ArgumentError` there may abort stream finalisation silently in BEAM's stream
  infrastructure.

### Costs

- One file changed, ~6 net lines removed.
- Callers must be audited to confirm neither wraps `close_port/1` in a rescue that would
  re-introduce the problem.
- No test surface change unless existing tests assert no crash on double-close; those tests
  would need to be updated to expect propagation or test the single-close path only.

## Dependencies

- Confirm `port_done/1` and the cancel branch in `port_next/2` tolerate an uncaught
  `ArgumentError` (or document that OTP supervision is the intended recovery path).
- No library changes.

## Confidence

Medium. The removal is structurally sound and the BEAM port semantics are well-known.
Confidence would rise to high after verifying the two call sites in their full execution
context (stream pipeline teardown) do not depend on the silent-`:ok` guarantee.

## Prior art / references

- Elixir `Port` module documentation: `Port.close/1` raises `ArgumentError` if the port
  is already closed — the idiomatic handling is a guard clause, not a rescue.
- OTP non-negotiables rule 7 (project `.claude/rules/otp-non-negotiables.md`): "Let it
  crash; supervise; restart."
- Elixir forum convention: prefer guard over rescue for `ArgumentError` on already-closed
  ports.
