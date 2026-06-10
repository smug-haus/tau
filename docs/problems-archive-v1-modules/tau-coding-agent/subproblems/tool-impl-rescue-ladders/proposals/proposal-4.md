---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Telemetry-instrumented rescue — emit `[:tau, :tools, :infrastructure_error]` events and preserve hard-fail propagation for critical paths

## Approach

Rewrite the three rescue sites as a two-tier strategy keyed on error severity:

1. For **`tau_session_status/1`** and **`safe_memory_load/1`** (non-critical
   convenience tools): keep the rescue but emit a `[:tau, :tools,
   :infrastructure_error]` telemetry event with `%{tool: atom(), reason: term()}`
   metadata before returning `{"available": false}`. The JSON response gains a
   `"result_kind"` discriminator field (as in Proposal 3) but the rescue stays
   to preserve soft-fail semantics for these tools.

2. For **`session_cwd/1`** (a cwd-resolution helper that silently biases
   downstream logic): remove the rescue entirely and propagate the crash. This is
   the one site where silent failure is actively harmful — `File.cwd!/0` fallback
   on a session-lookup crash is a latent correctness bug. The crash propagates to
   the MCP server supervisor, which restarts the process. A telemetry event is
   emitted before the rescue is removed via a `try/after` idiom (no `rescue`) to
   record the crash context before propagation.

This is a hybrid: the two "soft" sites become telemetry-observable; the one
"hard" site becomes correctly OTP-crash-propagating.

## Rationale

The three rescue sites are not equally harmful. `tau_session_status/1` returning
`available: false` on a crash is awkward but tolerable — the user-facing session
status tool failing with a soft response is not catastrophic. `safe_memory_load/1`
similarly: a memory query returning empty is a degraded-mode behaviour that a
subprocess can handle. But `session_cwd/1`'s rescue is qualitatively different:
it silently redirects all downstream computation to use `File.cwd!/0` instead of
the session-bound cwd, which is a correctness error, not a graceful degradation.
This proposal decomplects by *kind of harm* rather than uniformly applying one
strategy. The telemetry events make the soft-fail sites visible in production
metrics and logs, turning the "silent swallow" into an observable event without
changing the wire format for either soft-fail site.

## Sketch

```elixir
# New telemetry event in tau_session_status/1:
rescue
  e ->
    :telemetry.execute(
      [:tau, :tools, :infrastructure_error],
      %{count: 1},
      %{tool: :tau_session_status, reason: Exception.message(e), kind: :exception}
    )
    {:ok,
     encode(%{
       "available" => false,
       "result_kind" => "infrastructure_error",
       "reason" => "snapshot error: " <> Exception.message(e)
     })}
catch
  kind, reason ->
    :telemetry.execute(
      [:tau, :tools, :infrastructure_error],
      %{count: 1},
      %{tool: :tau_session_status, reason: inspect({kind, reason}), kind: :throw}
    )
    {:ok,
     encode(%{
       "available" => false,
       "result_kind" => "infrastructure_error",
       "reason" => "snapshot threw: #{inspect({kind, reason})}"
     })}

# safe_memory_load/1 — same telemetry pattern:
rescue
  e ->
    :telemetry.execute([:tau, :tools, :infrastructure_error], %{count: 1},
      %{tool: :safe_memory_load, reason: Exception.message(e), kind: :exception})
    {:error, "memory loader failed: " <> Exception.message(e)}
catch
  k, r ->
    :telemetry.execute([:tau, :tools, :infrastructure_error], %{count: 1},
      %{tool: :safe_memory_load, reason: inspect({k, r}), kind: :throw})
    {:error, "memory loader threw: #{inspect({k, r})}"}

# session_cwd/1 — rescue removed; crash propagates:
defp session_cwd(session_id) do
  case Tau.Session.snapshot(session_id) do
    {:ok, %{cwd: cwd}} when is_binary(cwd) -> cwd
    {:error, :not_found} -> nil
    {:error, _reason} -> nil
    # Unexpected return (e.g. malformed snapshot): pattern-match
    # exhaustion raises a CaseClauseError — supervisor handles it.
  end
  # No rescue/catch. Infrastructure crash propagates to supervisor.
end

# tau_memory_query/2 — add a telemetry-safe wrapper so session_cwd/1
# crashes are observable before propagating:
cwd =
  Map.get(state, :cwd) ||
    case Map.get(state, :session_id) do
      nil -> nil
      sid -> session_cwd(sid)   # crash propagates here if session_cwd/1 raises
    end ||
    File.cwd!()
```

Telemetry attachment (existing `OtelReporter` or `Logger`-based handler can
subscribe):
```elixir
# In application startup or test setup:
:telemetry.attach(
  "tau-tools-infra-error-logger",
  [:tau, :tools, :infrastructure_error],
  fn event, measurements, metadata, _config ->
    Logger.warning("tools infrastructure error",
      tool: metadata.tool,
      reason: metadata.reason,
      kind: metadata.kind
    )
  end,
  nil
)
```

File changes:
- `lib/tau/coding_agent/tau_context/tools.ex` — three sites; ~20 lines changed,
  ~15 lines added (telemetry calls).
- No new modules; telemetry handler attachment belongs in
  `lib/tau/application.ex` or `lib/tau/otel_reporter.ex`.

## Tradeoffs

### Strengths

- Differentiates by actual harm profile: the one site where silent failure causes
  correctness bugs (`session_cwd/1`) is fully fixed via OTP crash propagation.
- Infrastructure errors at the soft-fail sites become observable in production
  metrics and logs without changing the wire format for the subprocess caller.
- `result_kind` field makes the JSON structurally discriminable (same benefit as
  Proposals 1 and 3).
- Telemetry is already a first-class citizen in Tau (`[:tau, ...]` namespace);
  this follows an established pattern.
- The D-035 `{:ok, String.t()}` contract is preserved for `tau_session_status/1`
  and `tau_memory_query/2`.

### Weaknesses

- The soft-fail rescue sites still violate OTP non-negotiable §7 in principle —
  they are now *observed* violations rather than silent ones.
- Applying different strategies to different sites requires documentation: a
  future reader must understand why `session_cwd/1` does not rescue but the other
  two do. Without inline comments or a SPEC note, this looks inconsistent.
- Telemetry handler attachment adds a new wiring concern: if the handler is not
  attached, events fire and are silently dropped — the observability benefit
  disappears without any compile-time warning.
- The `session_cwd/1` crash propagation changes the behaviour of `tau_memory_query/2`:
  a previously soft-recoverable cwd-lookup failure now aborts the tool call. This
  is the *correct* behaviour, but it is a user-visible change.
- Adds `:telemetry` calls to private helpers — telemetry instrumentation is
  typically on public boundaries, not private functions; this may be seen as
  over-instrumentation.

### Costs

- ~35 lines changed or added in `tools.ex`.
- Telemetry handler registration: ~10 lines in `application.ex` or
  `otel_reporter.ex`.
- OTP non-negotiable §5: "Telemetry events MUST cover everything user-visible or
  perf-sensitive" — this is arguable for private helpers, so the SPEC-OTEL-REPORTER
  scope may need an amendment noting these events.
- A property test confirming `session_cwd/1` crash propagation would be required
  by spec-before-code.md if the change touches a SPEC boundary.

## Dependencies

- `Tau.OtelReporter` (or equivalent telemetry consumer) must be configured to
  subscribe to `[:tau, :tools, :infrastructure_error]` for the observability
  benefit to materialise; without this, telemetry fires into a vacuum.
- SPEC-OTEL-REPORTER §3 may need an amendment if the telemetry handler is wired
  into the reporter.
- Supervision topology confirmation: same as Proposal 2 — confirming that the MCP
  server process is supervised before removing `session_cwd/1`'s rescue.

## Confidence

medium — The hybrid strategy is principled (different sites have genuinely
different harm profiles), but the inconsistency it introduces requires careful
documentation and is a maintenance burden. Confidence would rise to high if there
is a documented policy in SPEC-CODING-AGENT that explicitly classifies tool call
sites as "soft-fail permitted" vs "must propagate", making the asymmetry a
governed choice rather than a local judgement.

## Prior art / references

- Tau `otp-non-negotiables.md` §5: "Telemetry events MUST cover everything
  user-visible or perf-sensitive" — used here as the observability hook for
  absorbed infrastructure errors.
- Erlang/OTP `:telemetry` library — standard BEAM observability substrate;
  used throughout `lib/tau/` already.
- Phoenix `Endpoint.call/2` error handling — uses a two-tier rescue (hard for
  Plug.Conn shape violations; soft for request-level errors) as a precedent for
  asymmetric rescue strategies within one module.
- `Tau.Session` FSM event telemetry (`[:tau, :session, ...]`) — existing
  precedent for per-event telemetry instrumentation inside Tau.
