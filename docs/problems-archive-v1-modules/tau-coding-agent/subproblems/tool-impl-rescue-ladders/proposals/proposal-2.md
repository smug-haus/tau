---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Remove the rescue ladders — let OTP handle infrastructure crashes, pattern-match only the expected tagged returns

## Approach

Delete all three `rescue`/`catch` blocks entirely. Replace each with explicit
pattern matching on the known tagged-tuple returns that `Tau.Session.snapshot/1`
and `MemoryLoader.load/1` already document. Infrastructure errors — crashes,
thrown terms, API shape violations — now propagate up the call stack to the
supervisor boundary, where the OTP process model handles them via restart. The
`session_cwd/1` helper's rescue is replaced with a `:error` clause in the `case`
match. `safe_memory_load/1` drops the outer `try` and relies on the caller to
receive a well-documented crash if `MemoryLoader.load/1` throws something
unexpected. The `tau_session_status/1` function handles `{:error, :not_found}`
(which it already does) and nothing else; other errors propagate.

## Rationale

The acceptance criterion explicitly names "removed because the calling code can
rely on the OTP process model instead of pre-emptive rescue" as a valid
resolution path. The three helpers are all called from within a supervised MCP
server process; if the process crashes on an unexpected infrastructure error, the
supervisor restarts it, and the coding-agent subprocess gets a clean connection
reset rather than a confusingly-shaped `available: false` response. This is
exactly the OTP non-negotiable §7 contract. Removing the rescues also removes the
complecting: "feature absent" is now the only code path that returns
`{"available": false}`, so infrastructure errors become visible by the absence of
a response (connection reset / process restart) rather than by a distinguishing
field. No new types, no new fields, no new protocol.

## Sketch

```elixir
# tau_session_status/1 — remove the rescue/catch entirely:
def tau_session_status(%{session_id: id}) when is_binary(id) do
  case Tau.Session.snapshot(id) do
    {:ok, snap} ->
      {:ok,
       encode(%{
         "available" => true,
         "session_id" => snap.id,
         "state" => Atom.to_string(snap.state),
         "message_count" => snap.message_count,
         "provider" => safe_inspect(snap.provider),
         "model" => snap.model,
         "cwd" => snap.cwd
       })}

    {:error, :not_found} ->
      {:ok,
       encode(%{
         "available" => false,
         "reason" => "session #{id} not registered (already stopped?)",
         "session_id" => id
       })}

    # Any other return from snapshot/1 is an unexpected contract violation:
    # let it crash — the supervisor handles it.
  end
end

# safe_memory_load/1 — drop the try/rescue/catch, keep only the
# Code.ensure_loaded? guard for the legitimate "not available" case:
defp safe_memory_load(cwd) do
  if Code.ensure_loaded?(MemoryLoader) and function_exported?(MemoryLoader, :load, 1) do
    entries = MemoryLoader.load(cwd)
    normalised = Enum.map(entries, fn {path, body} -> %{path: path, body: body} end)
    {:ok, normalised}
  else
    {:error, "Tau.Memory.Loader not available"}
  end
end

# session_cwd/1 — replace rescue with explicit pattern match:
defp session_cwd(session_id) do
  case Tau.Session.snapshot(session_id) do
    {:ok, %{cwd: cwd}} when is_binary(cwd) -> cwd
    {:error, :not_found} -> nil
    {:error, _} -> nil
    # Infrastructure crash propagates — supervisor restarts the process.
  end
end
```

File changes: only `lib/tau/coding_agent/tau_context/tools.ex`. Three sites, ~30
lines deleted. No new modules, no new types.

## Tradeoffs

### Strengths

- Fully satisfies OTP non-negotiable §7: infrastructure errors propagate to the
  supervisor boundary rather than being absorbed.
- Complecting is fully removed: `{"available": false}` now means only one thing —
  legitimate absence. There is no ambiguity to distinguish.
- Smallest code change by line count: deletions only, no new types or fields to
  document.
- No protocol change: `{"available": false}` shape is unchanged for all
  legitimate-absence paths.

### Weaknesses

- A coding-agent subprocess observing a connection reset or process restart after
  invoking a tool gets no structured reason for the failure. This is a user-facing
  regression: currently a snapshot crash at least returns a `reason` string; after
  this change the subprocess sees a hard failure with no error detail.
- `session_cwd/1` is called mid-computation in `tau_memory_query/2`. A crash
  there aborts the entire tool call, including the cwd fallback. The current
  `nil`-return behaviour is undocumented but used by consumers; removing it is an
  observable behaviour change even if it is "more correct".
- `safe_memory_load/1` without a rescue is exposed to `MemoryLoader.load/1`
  throwing non-Exception terms. Elixir's `rescue` catches only `Exception`-derived
  structs; the current `catch kind, reason` guard also catches `:exit` and bare
  throws. Without it, an `exit` from `MemoryLoader.load/1` propagates as an
  unlinked exit signal, which may or may not be handled by the supervisor
  depending on process link topology.
- Requires downstream consumer (coding-agent subprocess) to handle hard connection
  resets as a distinct error case — currently it only handles the soft
  `available: false` path.

### Costs

- Pure deletion: ~30 lines removed, no new code.
- The behaviour change for infrastructure errors is observable: subprocess code
  that currently logs `reason` strings from `available: false` bodies will stop
  seeing those messages and will instead see a connection-level failure.
- If `MemoryLoader.load/1`'s exit behaviour is not documented, a test must be
  written to confirm the supervisor restart semantics are correct. This is a
  non-trivial test requirement.

## Dependencies

- Requires confirmation that the MCP server process supervising the `Tools` module
  is configured for restart on crash (`:one_for_one` or similar) — otherwise
  removing the rescue degrades resilience without a safety net.
- Requires coding-agent subprocess protocol handling for connection resets, or
  at minimum a documented decision that hard-resets on tool calls are acceptable.
- If `MemoryLoader.load/1` can throw `:exit` terms, the supervision strategy for
  the owning process must explicitly tolerate exit propagation.

## Confidence

medium — The OTP rationale is sound and fully aligns with the acceptance criterion
and non-negotiable §7. Confidence is held at medium (not high) because the
behavioural change to the subprocess error surface is real and the supervision
topology of the MCP server process has not been verified in this audit.

## Prior art / references

- OTP non-negotiables §7 (`otp-non-negotiables.md`): "Let it crash; supervise;
  restart. MUST NOT `try/rescue` across process boundaries."
- Erlang/OTP supervisor documentation — processes should crash on unexpected
  conditions and rely on supervisor restart for recovery.
- Tau `Tau.CircuitBreaker` — does not wrap `Store` ETS reads in rescue; lets the
  process crash on unexpected ETS errors.
