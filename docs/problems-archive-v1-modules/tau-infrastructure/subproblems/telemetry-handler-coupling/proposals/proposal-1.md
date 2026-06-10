---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Symmetric rescue in handle_event/4 + :rest_for_one supervisor strategy

## Approach

Add a `rescue` block to `Tau.Cost.Tracker.handle_event/4` that mirrors the
existing guard in `handle_coding_agent_cost/4`, emitting
`[:tau, :cost, :tracker, :handler_failed]` on error and returning `:ok`. In
the same PR, change `Tau.Telemetry.Supervisor.init/1` from
`strategy: :one_for_one` to `strategy: :rest_for_one`. No new modules, no
interface changes, no API breakage — two targeted edits in two files.

## Rationale

`handle_event/4` already has the correct structural guard (the `with`/`else`
chain drops bad shapes silently), but it lacks a `rescue` around the `:ets`
call path that is reachable when `usage` passes `is_map` but contains a
non-integer value that slips past `nz/1` (e.g. a float). The coding-agent
twin's `rescue` is the D-035-mandated pattern; the fix is literal symmetry.
The supervisor change decomplects handler-attachment lifecycle from supervisor
strategy: under `:rest_for_one`, a `Handlers` crash cascades left-to-right
through the child list so `Cost.Tracker` restarts too, forcing its `init/1`
to re-`detach`-then-`attach` cleanly. The attachment lifecycle is then
expressed by the child ordering in the supervisor, not by an invisible side
effect of what happened to survive.

## Sketch

**`lib/tau/cost/tracker.ex` — add rescue to `handle_event/4`:**

```elixir
@doc false
def handle_event(_event, measurements, metadata, _config) do
  with provider when is_atom(provider) and not is_nil(provider) <- metadata[:provider],
       session_id when is_binary(session_id) <- metadata[:session_id],
       usage when is_map(usage) <- measurements[:usage] do
    key = {today_iso(), provider, metadata[:model], session_id}

    input = nz(usage[:input_tokens])
    output = nz(usage[:output_tokens])
    cr     = nz(usage[:cache_read])
    cw     = nz(usage[:cache_write])

    :ets.update_counter(
      @table,
      key,
      [{2, input}, {3, output}, {4, cr}, {5, cw}],
      {key, 0, 0, 0, 0}
    )
  else
    _ -> :ok
  end
rescue
  e ->
    :telemetry.execute(
      [:tau, :cost, :tracker, :handler_failed],
      %{system_time: System.system_time()},
      %{reason: Exception.message(e)}
    )
    :ok
end
```

**`lib/tau/telemetry/supervisor.ex` — change strategy:**

```elixir
@impl true
def init(_opts) do
  children = [
    Tau.Telemetry.Handlers,   # index 0 — if this crashes, index 1+ restart
    Tau.Cost.Tracker          # index 1 — re-attaches its own handlers on init
  ]

  Supervisor.init(children, strategy: :rest_for_one)
end
```

Child ordering matters: `Handlers` must remain listed before `Cost.Tracker`
so a `Handlers` crash cascades to `Cost.Tracker`, not the reverse.

## Tradeoffs

### Strengths

- Minimal diff: two files, ~10 lines changed; easy to review and revert.
- Directly symmetric with the existing `handle_coding_agent_cost/4` pattern,
  so no new idiom is introduced.
- `:rest_for_one` explicitly encodes the attachment dependency in the child
  list ordering, making the invariant visible in the source.
- Zero consumer-facing API change.
- Satisfies both acceptance criterion parts (a) and (b) independently.

### Weaknesses

- `:rest_for_one` restarts `Cost.Tracker` on every `Handlers` crash — even
  those unrelated to cost tracking. In the common path (no crash), this is
  irrelevant, but a flapping `Handlers` would repeatedly reset in-flight
  cost counters (ETS table is re-created on `Cost.Tracker.init/1`).
- The supervisor strategy change is invisible to static analysis; reviewers
  must mentally walk the child list to confirm ordering is correct.
- Does not address the broader question of whether `Cost.Tracker` should
  self-manage its handler lifecycle independently of `Handlers`.
- `nz/1` returning `0` for a non-integer silently absorbs malformed provider
  data; the rescue prevents a crash but does not surface the data error to
  the provider adapter. That remains an acceptable silent drop per D-035.

### Costs

- 2 files changed, ~10 lines net.
- Test surface: add one test asserting `handle_event/4` returns `:ok` and
  emits `[:tau, :cost, :tracker, :handler_failed]` when `:ets.update_counter`
  would raise (e.g. inject a float via a mock measurement). The coding-agent
  twin's existing test provides the pattern.
- No dependency changes; no migration.

## Dependencies

- None. This is a self-contained change within `Tau.Telemetry.Supervisor`
  and `Tau.Cost.Tracker`.

## Confidence

medium — the rescue pattern is proven by the coding-agent twin; the
`:rest_for_one` change is standard OTP. Confidence would be high after
confirming that `Cost.Tracker.terminate/2` calls `:telemetry.detach/1`
(it does, line 112-114), so the ETS table destruction + handler detach on
restart is clean.

## Prior art / references

- `Tau.Cost.Tracker.handle_coding_agent_cost/4` lines 144-172 — the exact
  rescue pattern to mirror.
- `Tau.Cost.Tracker.terminate/2` lines 111-115 — confirms detach-on-terminate
  makes `:rest_for_one` restart safe.
- OTP non-negotiables §7: "Let it crash; supervise; restart. MUST NOT
  try/rescue across process boundaries." — rescue inside a telemetry handler
  is intra-process; D-035 explicitly requires it; no contradiction.
- Erlang/OTP supervisor docs: `:rest_for_one` — children after the crashed
  child are restarted left-to-right after the crashed child recovers.
