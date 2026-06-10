---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Delete safe_list/safe_reload and let GenServer calls crash normally

## Approach

Remove `safe_list/0` and `safe_reload/0` entirely from `Tau.CLI.Extensions` and
`Tau.CLI.MCP`. The call sites — `list/1`, `status/1`, and `reload/1` — call the
supervised GenServers directly (`Tau.Extensions.Loader.list/0`,
`Tau.MCP.Reconciler.list/0`, etc.) with no rescue/catch wrapper. An `:exit,
:noproc` or any other process exception propagates to `Tau.CLI.main/1`, which
already wraps its dispatch in a top-level rescue that converts unhandled
exceptions to exit code 1 with an error message to stderr. The operator sees a
traceable crash-report rather than an empty-result lie.

## Rationale

The complecting hypothesis identifies a single woven concern: error-reporting
coupled inside the data-fetch function. The simplest decomplecting move is
deletion — the rescue shim is the coupling; removing it exposes the two
concerns separately (data retrieval raises naturally; the top-level CLI boundary
handles exit codes). OTP NN #7 forbids `try/rescue` across process boundaries
exactly because a `:noproc` exit is a meaningful signal, not an empty result.
Deletion preserves that signal with zero new code.

## Sketch

**`lib/tau/cli/extensions.ex` — before (lines 67–81):**
```elixir
defp safe_list do
  Tau.Extensions.Loader.list()
rescue
  _ -> []
catch
  :exit, _ -> []
end

defp safe_reload do
  Tau.Extensions.Loader.reload_all()
rescue
  e -> {:error, Exception.message(e)}
catch
  :exit, reason -> {:error, reason}
end
```

**After — `safe_list/0` and `safe_reload/0` deleted; call sites updated:**
```elixir
# In list/1 — was: entries = safe_list()
entries = Tau.Extensions.Loader.list()

# In reload/1 — was: case safe_reload() do
case Tau.Extensions.Loader.reload_all() do
```

Same pattern in `lib/tau/cli/mcp.ex` (lines 98–112): delete both private
functions, inline the direct calls.

**Expected runtime behaviour on `:noproc`:**

`Tau.CLI.main/1` top-level rescue (if present) catches the exit and emits:
```
Error: Extensions.Loader process unavailable: :noproc
```
exit code 1. If no top-level rescue exists today, one must be added (see
Dependencies).

**Signature change summary:**
- `Tau.CLI.Extensions.list/1` — `@spec` return type unchanged (`0`), but now
  may raise rather than always returning `0` on crash.
- `Tau.CLI.Extensions.reload/1` — same.
- `Tau.CLI.MCP.list/1`, `status/1`, `reload/1` — same.

## Tradeoffs

### Strengths

- Smallest diff: deletes ~30 lines, adds 0. Least opportunity for new defects.
- Directly satisfies OTP NN #7 with no new abstraction.
- Full crash information (stacktrace + reason) reaches the operator.
- Acceptance criterion satisfied: non-zero exit + stderr diagnostic on process
  unavailability, sourced from the top-level handler.

### Weaknesses

- **Error message quality depends on the top-level rescue.** If `Tau.CLI.main/1`
  does not currently produce a human-readable message for `:exit, :noproc`, the
  operator sees a raw Elixir term rather than a diagnostic. Requires audit of
  the top-level boundary.
- **Loss of the `{:error, reason}` tagged-tuple contract** that `reload/1`
  currently relies on from `safe_reload/0`. The `case` in `reload/1` must be
  restructured (the `{:error, reason}` arm disappears; the only error path is
  via exception propagation). The existing `IO.puts(:stderr, "... reload
  failed")` branch becomes unreachable.
- **No per-command granularity.** A callee crash produces a uniform "unhandled
  exception" message rather than "extensions reload failed" or "mcp list
  unavailable". The error is real but the context is coarser.
- **`list/1` spec claim of always returning `0` becomes stale.** The spec must
  be updated or the top-level handler must be documented as the exit-code
  owner.

### Costs

- ~30 lines deleted; ~10 lines changed (inlining call sites, restructuring
  reload/1's case branches).
- Must audit `Tau.CLI.main/1` (or wherever `list/1` / `reload/1` are called)
  to confirm a top-level exception-to-exit-code boundary exists and produces
  readable output.
- One test change: tests that assert `list/1` returns `0` when the loader is
  down must be updated to assert raise/exit propagation or test at the `main/1`
  boundary instead.

## Dependencies

- `Tau.CLI.main/1` (or the outermost dispatch in `lib/tau/cli.ex`) MUST have a
  top-level rescue that converts unhandled exceptions/exits to exit code 1 and
  emits a diagnostic to stderr. If absent, this must be added in the same PR.
- No library additions required.

## Confidence

medium — the deletion is mechanically straightforward; confidence is bounded by
not having audited whether `main/1` already provides an adequate top-level
boundary. If it does, confidence rises to high.

## Prior art / references

- OTP NN #7: "Let it crash; supervise; restart. MUST NOT `try/rescue` across
  process boundaries. MUST NOT catch `:exit`." — the non-negotiable this
  directly satisfies.
- Erlang/OTP "let-it-crash" philosophy: errors propagate until an intentional
  boundary; CLI binaries are natural boundaries (process exit maps directly to
  shell exit code).
- Elixir `System.stop/1` / `exit/1` patterns for CLI exit codes in Burrito
  releases: process exits from GenServer calls in a Burrito binary terminate
  the VM with the exit reason, which Burrito maps to exit code 1 by default.
