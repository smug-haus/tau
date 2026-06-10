---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Subscribe-before-start wrapper around Tau.Session.stream/2

## Approach

Fix the D-004 constraint directly: extend `Tau.Session.stream/2` (or add a new
`Tau.Session.stream_from/2` variant) to accept an already-open subscription
handle rather than subscribing internally. `run_cmd/1` subscribes manually as it
does today, then passes the subscription handle to the stream constructor; the
stream function's setup phase becomes a no-op when a handle is supplied. The
`drain_run_loop/2` and `drain_session_end/2` raw-`receive` bodies are deleted
and replaced by a pipeline over `Tau.Session.stream_from/2 |> Enum.reduce_while`.

## Rationale

The D-004 comment in `cli.ex` explains exactly why `Tau.stream/2` is currently
bypassed: subscription happens lazily inside `Stream.resource/3`'s setup
function, which fires only on first pull — after `start_session` may have
broadcast `SessionStart`. The fix is to accept an already-open subscription,
making the stream's setup idempotent. This decomplects subscription timing from
the stream's inner loop, removes the raw `receive`, and gives the stream's
`after` clause (60 s timeout → `:halt`) the correct semantics for headless use
rather than requiring a bespoke `after 10_000` timeout. Unknown events are
handled by the existing passthrough clause (`msg when is_struct(msg)`) in the
stream rather than silently discarded.

## Sketch

```elixir
# lib/tau/session.ex — new variant (or new arity on stream/2)
@spec stream_from(id(), :already_subscribed, keyword()) :: Enumerable.t()
def stream_from(id, :already_subscribed, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 60_000)
  Stream.resource(
    fn -> :ok end,   # subscriber already holds the mailbox
    fn :ok ->
      receive do
        %Events.SessionEnd{session_id: ^id} = e -> {[e], :halt}
        msg when is_struct(msg) -> {[msg], :ok}
        _other -> {[], :ok}   # non-struct messages dropped without silencing Events.*
      after
        timeout -> {:halt, :ok}
      end
    end,
    fn _ -> :ok end
  )
end

# lib/tau/cli.ex — run_cmd/1 (replacement for drain_run_loop / drain_session_end)
Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")

session_id
|> Tau.Session.stream_from(:already_subscribed, timeout: 10_000)
|> Enum.reduce_while({%{}, 0}, fn event, {tool_names, _exit_code} ->
  case event do
    %Events.MessageEnd{message: msg} ->
      handle_message_end(msg, session_id, tool_names)

    %Events.SessionEnd{reason: reason} ->
      code = if reason in [:normal, :user], do: 0, else: 1
      {:halt, {tool_names, code}}

    %Events.ToolStart{tool_call_id: id, name: name, arguments: args} ->
      IO.puts(:stderr, "[tau] → #{name}(#{summarise_args(args)})")
      {:cont, {Map.put(tool_names, id, name), 0}}

    %Events.ToolEnd{tool_call_id: id, result: result} ->
      name = Map.get(tool_names, id, "?")
      marker = if is_struct(result, Tau.Message.ToolResult) && result.is_error, do: "✗", else: "✓"
      IO.puts(:stderr, "[tau] ← #{name} #{marker}")
      {:cont, {Map.delete(tool_names, id), 0}}

    _unknown ->
      # Unknown Events.* struct: log at debug, do not discard silently
      Logger.debug("[tau] drain: unhandled event #{inspect(event.__struct__)}")
      {:cont, {tool_names, 0}}
  end
end)
|> then(fn {_tool_names, exit_code} -> exit_code end)
```

Timeout semantics: the stream's `after` timeout fires when no event arrives
within the window. The `Enum.reduce_while` pipeline will exhaust (returning the
accumulator) — the final `exit_code` in the accumulator is `0` by default,
which is wrong if `SessionEnd` never arrived. Fix: sentinel initial exit code
of `1` plus a `:halt` on `SessionEnd`:

```elixir
# Initial accumulator uses 1 (fail-safe) until SessionEnd delivers the correct code
|> Enum.reduce_while({%{}, 1}, ...)
```

`drain_session_end` disappears entirely; the stream's timeout becomes the drain
window, and a missing `SessionEnd` yields exit code 1 rather than the
caller-seeded value.

## Tradeoffs

### Strengths

- Removes both raw `receive` functions entirely; the entire event loop becomes a
  single `Enum.reduce_while` over a typed stream.
- Unknown `Events.*` structs are no longer silently discarded; they hit the
  `_unknown` clause and can be logged.
- `drain_session_end/2`'s silent false-positive on timeout is fixed: initial
  accumulator carries `1`; only `SessionEnd` delivers `0`.
- D-004 invariant preserved: subscription still precedes `start_session`.
- `Tau.Session.stream_from/2` is reusable by any headless consumer that needs to
  subscribe before starting.
- Behaviour-preserving for all currently handled events.

### Weaknesses

- Adds a second entry point to `Tau.Session`'s stream API; callers must
  understand the `:already_subscribed` sentinel contract.
- The `after` clause in `stream_from/2` halts with no `SessionEnd` in the
  accumulator — the calling code must treat the stream's natural exhaustion as a
  timeout signal, which requires care in the `reduce_while` accumulator design.
- Progress rendering (`IO.puts`) remains coupled to the event loop; this
  proposal does not separate those concerns.
- Does not fix the `run_cmd/1` size or its `try/after` coupling (out of scope,
  but still visible).

### Costs

- `Tau.Session` gains one new exported function (or a new arity on `stream/2`).
- `drain_run_loop/2` and `drain_session_end/2` are deleted (~60 lines removed,
  ~35 lines of pipeline added).
- Any test that exercises `drain_run_loop/2` / `drain_session_end/2` directly
  must be rewritten against the pipeline (small: these functions are `@doc false`).
- No dependency changes.

## Dependencies

- None. `Tau.Session.stream_from/2` depends only on `Phoenix.PubSub` and the
  existing `Events` module, both already in scope.

## Confidence

Medium. The approach is straightforward; the D-004 fix and the accumulator
design are both clear. Confidence would be high after a prototype run confirming
that the stream's `after` clause fires correctly on a timeout and that the
reduce-while terminates on `SessionEnd`.

## Prior art / references

- `Tau.Session.stream/2` (`lib/tau/session.ex:175`) — the existing `Stream.resource` pattern being extended.
- D-004 comment at `lib/tau/cli.ex:296-299` — explicit description of the constraint being addressed.
- Elixir `Stream.resource/3` docs — setup/next/cleanup contract.
