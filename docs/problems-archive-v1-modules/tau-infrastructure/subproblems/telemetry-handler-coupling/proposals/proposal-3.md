---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Cost.Tracker self-manages handler detach/re-attach on sibling crash via PubSub monitoring — no supervisor strategy change

## Approach

Keep `Tau.Telemetry.Supervisor` at `:one_for_one`. Instead, add a
`handle_info/2` clause to `Tau.Cost.Tracker` that monitors `Tau.Telemetry.Handlers`
via `Process.monitor/1` and re-attaches (detach → attach) its own handlers
when it receives a `{:DOWN, ...}` notification for `Handlers`. Add the `rescue`
to `handle_event/4` as in Proposal 1. The handler-attachment lifecycle is then
an explicit, self-describing behaviour inside `Cost.Tracker`, not an implicit
consequence of supervisor restart ordering.

## Rationale

The second complecting hypothesis states that handler-attachment lifecycle is
determined by supervisor strategy rather than by explicit lifecycle logic.
Proposal 1 and 2 address this by making the supervisor strategy encode the
dependency. This proposal instead decomplects by making `Cost.Tracker`
explicitly aware of its sibling's lifecycle: the attachment is expressed as
a reaction to a `:DOWN` message, not as a side effect of child-list ordering.
This approach keeps the supervisor strategy at `:one_for_one` (no change to
restart scopes), avoids cascade-restarting `Cost.Tracker` on every `Handlers`
crash, and makes the re-attach logic visible and testable without touching
the supervisor.

## Sketch

**`lib/tau/cost/tracker.ex` — add monitor + DOWN handler in `init/1` and
`handle_info/2`:**

```elixir
@impl true
def init(_opts) do
  :ets.new(@table, [:named_table, :public, :set,
                    read_concurrency: true, write_concurrency: true])
  attach_handlers()

  # Monitor Handlers so we can re-attach if it crashes and restarts.
  # We watch by name; if Handlers is not yet started we receive :DOWN
  # with reason :noproc and re-try once supervision stabilises.
  if pid = Process.whereis(Tau.Telemetry.Handlers) do
    Process.monitor(pid)
  end

  {:ok, %{}}
end

@impl true
def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
  # Handlers crashed and will be restarted by its own supervisor child spec.
  # Detach and re-attach our handlers to clear any stale registration.
  :telemetry.detach(@handler_id)
  :telemetry.detach(@coding_agent_handler_id)
  attach_handlers()

  # Re-monitor the new Handlers pid once it is up.
  # Retry with a brief delay to let the supervisor restart it.
  Process.send_after(self(), :remonitor_handlers, 100)
  {:noreply, state}
end

def handle_info(:remonitor_handlers, state) do
  if pid = Process.whereis(Tau.Telemetry.Handlers) do
    Process.monitor(pid)
  else
    # Handlers still not up; retry once more.
    Process.send_after(self(), :remonitor_handlers, 500)
  end
  {:noreply, state}
end

# --- private ---

defp attach_handlers do
  :telemetry.attach(@handler_id, [:tau, :provider, :request, :stop],
                    &__MODULE__.handle_event/4, nil)
  :telemetry.attach(@coding_agent_handler_id, [:tau, :coding_agent, :cost],
                    &__MODULE__.handle_coding_agent_cost/4, nil)
end
```

**`lib/tau/cost/tracker.ex` — add rescue to `handle_event/4`** (identical to
Proposal 1 sketch).

**`lib/tau/telemetry/supervisor.ex`** — NO change; strategy remains
`:one_for_one`.

## Tradeoffs

### Strengths

- Decomplects attachment lifecycle from supervisor strategy: the dependency
  is expressed in code (monitor + DOWN handler), not in child-list order.
- Avoids cascading `Cost.Tracker` restart on every `Handlers` crash, so
  in-flight cost counters (ETS contents) are preserved across `Handlers`
  crashes.
- The re-attach logic is independently testable: send a mock `:DOWN` message
  to the tracker and assert handlers are re-attached.
- No change to the supervisor's restart scope; side-effect containment is
  better.

### Weaknesses

- Adds retry-loop logic (`send_after :remonitor_handlers`) which is more
  complex than the supervisor change and has a race window: events fired
  between `Handlers` crash and `Cost.Tracker`'s re-attach are silently
  dropped (no `:DOWN` handler is attached during that window).
- `Process.whereis/1` → `Process.monitor/1` creates a TOCTOU race at startup
  if `Handlers` crashes between the two calls; `:DOWN` with `:noproc` is
  handled, but the window is inelegant.
- The OTP non-negotiables §4 say "Cross-process events MUST use `Phoenix.PubSub`
  or monitored refs". Monitored refs are permitted, but the monitor-in-`init/1`
  idiom requires `Handlers` to be started before `Cost.Tracker` (or the initial
  monitor silently does nothing), adding an implicit startup order dependency
  that `:rest_for_one` would make explicit.
- More lines of code and more moving parts than Proposals 1 or 2.
- The 100 ms / 500 ms retry delays are magic numbers; they may be too short
  under load or add unnecessary latency to the re-attach in tests.

### Costs

- ~30 lines added to `tracker.ex`; no new files.
- Test surface: new test cases for the `:DOWN` handler (send mock `:DOWN`
  to tracker, assert handler re-attaches) and the `:remonitor_handlers`
  retry path. The timing constants are a test friction point.
- No dependency changes; no migration.

## Dependencies

- `Tau.Telemetry.Handlers` must export its registered name (currently
  `__MODULE__`, i.e., `Tau.Telemetry.Handlers`) so that
  `Process.whereis(Tau.Telemetry.Handlers)` works. It does.

## Confidence

low — the explicit monitoring approach is correct in principle, but the
retry-delay complexity and the startup-order dependency it implicitly
creates make this approach harder to reason about than the supervisor
strategy change. Confidence would be raised by a prototype demonstrating
the retry loop behaves correctly under fast supervisor restarts in test.

## Prior art / references

- OTP non-negotiables §4: "monitored refs" are an approved cross-process
  coordination primitive.
- Erlang patterns: GenServer monitoring a sibling with `Process.monitor/1`
  in `init/1` is a known pattern for "sibling-aware" processes.
- Counterpoint: `:rest_for_one` exists precisely to encode restart dependency
  in the supervisor — using a monitor instead may be working around the
  designed idiom.
