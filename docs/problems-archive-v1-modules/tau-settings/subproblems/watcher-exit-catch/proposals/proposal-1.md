---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Pattern-match on FileSystem.start_link/1 return value only

## Approach

Remove the `try/rescue/catch` block entirely from `maybe_start_watcher/1`. The
`true ->` arm of the `cond` becomes a plain `case FileSystem.start_link(dirs: dirs)`
expression. Only the return-value arms `{:ok, pid}` and `other ->` are kept. No
exception or exit interception. Any `:exit` from `FileSystem.start_link/1` propagates
to the `Tau.Settings.Watcher` GenServer's `init/1`, which returns `{:stop, reason}`
to its supervisor — correctly signalling init failure.

## Rationale

`FileSystem.start_link/1` is documented to return `{:ok, pid}` on success and
`{:error, reason}` on known-soft failures (`:no_dirs`, bad config). An `:exit` is not
in its documented return-value domain — it is a supervisor-level crash signal. The
current `catch :exit` arm treats the two categories as equivalent: it converts an OTP
crash into a soft `{:error, reason}` tuple, hiding the crash from the supervision
tree. Removing the catch means the OTP signal propagates naturally: the `Watcher`'s
`init/1` sees the exit, returns `{:stop, reason}`, and the supervisor records the
failure. The degraded-mode path (`watcher: nil`) continues to fire for all values
`FileSystem.start_link/1` actually returns normally.

## Sketch

```elixir
defp maybe_start_watcher(dirs) do
  cond do
    not Code.ensure_loaded?(FileSystem) ->
      {:error, :file_system_not_loaded}

    dirs == [] ->
      {:error, :no_dirs}

    true ->
      case FileSystem.start_link(dirs: dirs) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          {:ok, pid}

        other ->
          {:error, other}
      end
  end
end
```

`init/1` is unchanged. When `maybe_start_watcher/1` returns `{:error, _}` the
`other ->` arm in `init/1` fires, sets `watcher: nil`, emits telemetry — exactly
as today. When `FileSystem.start_link/1` exits, the exit propagates through
`maybe_start_watcher/1` and through `init/1`, reaching the supervisor as an
init failure, which is the correct OTP behaviour.

No callers outside `init/1` invoke `maybe_start_watcher/1`, so no callsite
changes are needed.

## Tradeoffs

### Strengths

- Minimal diff: removes 5 lines, changes 0 signatures — the lowest-disruption
  path to OTP NN #7 compliance.
- Exactly satisfies the acceptance criterion: `catch :exit` is gone; pattern
  matching on the return value handles legitimate failures; degraded-mode
  telemetry is unaffected.
- The resulting code is idiomatic Elixir: `FileSystem.start_link/1` failure
  reads as data, crash reads as a crash.
- No new module, no new dependency, no behaviour change for the normal or
  soft-failure paths.

### Weaknesses

- If a `FileSystem` version surfaces that raises (not exits) on bad input, the
  `rescue` arm removal would drop that protection too. (Currently `rescue e`
  captures `Exception.message(e)` — this disappears.) Whether this matters
  depends on `FileSystem` library behaviour, which is not under Tau's control.
- The `Watcher` supervisor must be configured with an appropriate restart
  strategy (`:transient` or `:temporary`) if the intent is that a
  `FileSystem` crash should not repeatedly restart the Watcher. This
  proposal does not touch the supervision tree, so the caller's restart
  policy is unchanged; that may be correct or incorrect depending on intent.
- No test is added for the `:exit` propagation path — the acceptance criterion
  does not require one, but the hole in coverage remains.

### Costs

- ~5 lines deleted, 0 lines added. One file changed: `lib/tau/settings/watcher.ex`.
- Existing tests are unaffected (the `dirs: []` path still hits the `cond`
  short-circuit before reaching `FileSystem.start_link/1`).
- No library changes, no migration.

## Dependencies

- None. This proposal is self-contained.

## Confidence

high — the code change is a mechanical deletion of the `try` block; the
remaining pattern is standard Elixir. Confidence would only decrease if
`FileSystem.start_link/1` were known to raise (not exit) in a way that
matters for Tau's operation.

## Prior art / references

- OTP NN #7: "MUST NOT `try/rescue` across process boundaries. MUST NOT catch `:exit`."
- Elixir `GenServer` docs: `init/1` returning `{:stop, reason}` is the canonical
  way to signal an init failure to the supervisor.
- `FileSystem.start_link/1` source (GitHub: lexmag/file_system) — returns
  `GenServer.start_link/3` result; does not document raised exceptions.
