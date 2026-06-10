---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-3.md]
selection_method: hybrid
revision: 0
---

# Solution: Stream-from variant with pure classify_event/2 as fold kernel

## Recommendation

Extend `Tau.Session` with a `stream_from/3` variant that accepts an
already-open subscription handle (satisfying D-004 without a hand-rolled
handshake), and drive the headless drain via a single `Enum.reduce_while`
whose reducer is an extracted, pure `classify_event/2` function. Rendering
is decomplected into a separate `render_event/1` pure function called
before the classify step. `drain_run_loop/2` and `drain_session_end/2` are
deleted. Unknown `Events.*` structs log at `:debug` via the `classify_event`
fallback clause and do not silently recurse. A missing `SessionEnd` yields
exit code `1` because the initial reduce accumulator is `{%{}, 1}`.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` and `proposals/proposal-3.md`
- **Why chosen:** Proposal 1 provides the cleanest elimination of raw `receive`
  by routing through the existing `Stream.resource/3` abstraction in
  `Tau.Session`, preserving the project's established stream idiom and satisfying
  D-004 without a bespoke inter-process handshake. Its weakness is that rendering
  and control-flow remain entangled in the `reduce_while` body. Proposal 3
  addresses exactly that complecting by extracting `classify_event/2` (pure,
  property-testable) and `render_event/1` (pure side-effect) as named functions —
  but it retains a raw `receive` loop inside a `Task` and introduces a
  `{:subscribed, ref}` / `{:start, ref}` hand-rolled synchronisation that
  replaces one OTP violation with another form of process-coordination boilerplate.
  The hybrid takes Proposal 1's stream-based drain (no raw `receive`, no
  hand-rolled handshake, D-004 via `init/1`-equivalent subscription-before-start)
  and Proposal 3's pure-function decomposition of the reducer body. The result
  is a `reduce_while` whose per-event logic is `render_event/1` → `classify_event/2`,
  each independently testable, with the stream machinery handling receive and
  timeout. Proposal 2's GenServer adds a new supervised process and a remaining
  raw `receive` in `run_cmd/1` for the result handoff; it scores lower on
  reversibility and adds more infrastructure than the problem warrants. Proposal 4
  introduces three new files and an `Application.get_env` plug seam for a single
  callsite; the behaviour extensibility is over-engineered relative to the
  acceptance criterion, which does not require pluggability.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|--------------------|-----------------|----|--------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Substantial | Medium | Medium | Medium |
| 3 | Partially | Substantial | Low | Medium | Easy |
| 4 | Yes | Substantial | High | Low–Medium | Medium |

Proposal 3 scores "Partially" on fit because its raw `receive` inside a `Task`
is still a raw `receive` loop; stricter reading of OTP NN #4 flags it as
non-compliant even when in the subscriber process. Proposal 1 and the hybrid
eliminate raw `receive` entirely.

## What changes

- **`lib/tau/session.ex`** — add `stream_from/3` (or `stream/3` with an
  `:already_subscribed` sentinel) that skips internal subscription, using
  `Stream.resource/3` with a no-op setup, the same `receive` body as the
  existing `stream/2`, and `after timeout -> {:halt, :ok}`.
- **`lib/tau/cli.ex`** — replace `drain_run_loop/2` and `drain_session_end/2`
  with:
  - `classify_event/2` — pure function, `struct() × map() → {:continue, map()} | {:halt, 0|1}`, handles all current event types plus a fallback `Logger.debug` clause.
  - `render_event/1` — pure side-effecting function, `struct() → :ok`, handles `ToolStart` / `ToolEnd` progress output.
  - Inline `run_cmd/1` drain: `Tau.Session.stream_from(session_id, :already_subscribed, timeout: 10_000) |> Enum.reduce_while({%{}, 1}, fn e, {names, _} -> render_event(e); classify_event(e, names) end) |> elem(1)`.
- **Tests** — any test exercising `drain_run_loop/2` / `drain_session_end/2`
  directly is rewritten as pure unit tests over `classify_event/2` (no process
  setup required) and integration tests over `stream_from`.

## What does not change

- D-004 subscribe-before-start invariant: `run_cmd/1` still calls
  `Phoenix.PubSub.subscribe/2` before `Tau.start_session/1`; `stream_from`'s
  setup is a no-op that respects the already-open subscription.
- `Tau.Session.stream/2` — existing callers unaffected.
- `run_cmd/1`'s `try/after` wrapping `Tau.send/2` for telemetry-handler
  detachment — explicitly out of scope, remains as-is.
- All currently handled event types (`MessageEnd`, `SessionEnd`, `ToolStart`,
  `ToolEnd`) — behaviour-preserving.
- No new dependencies, no new supervised processes.

## Migration sketch

1. Add `Tau.Session.stream_from/3` with tests confirming: (a) timeout fires
   when no `SessionEnd` arrives, (b) the stream yields all events before halt.
2. Extract `classify_event/2` and `render_event/1` as private functions in
   `cli.ex`; write pure unit tests for both (no process infra needed).
3. Replace the `drain_run_loop/2` call in `run_cmd/1` with the
   `stream_from |> reduce_while` pipeline; delete `drain_run_loop/2` and
   `drain_session_end/2`.
4. Run full test suite; confirm `mix compile --warnings-as-errors` clean.

Steps 1 and 2 can land together; step 3 is the deleting change that must pass
the existing integration tests.

## Open questions

- The `stream_from/3` setup no-op relies on the caller having subscribed to
  the correct topic before the stream is constructed; if the topic string is
  mis-formed, the stream silently drains nothing. A guard or a `{:ok, pid}` /
  `{:error, :not_subscribed}` return from the setup phase would make this
  contract visible.
- `render_event/1` for `ToolEnd` needs the `tool_names` map to look up the
  tool name by ID. The pure-function boundary requires either (a) enriching the
  event before calling `render_event` or (b) accepting that `render_event` for
  `ToolEnd` takes `(event, tool_names)` — breaking the single-arity signature.
  This is the known incomplete point from Proposal 3; the implementer must
  resolve it (passing `tool_names` as a second argument to `render_event/1` for
  `ToolEnd` is the simplest fix).
- Timeout value: the current `drain_session_end/2` uses `10_000` ms; `stream/2`
  uses `60_000` ms. The hybrid should settle on one value or make it configurable
  via `run_cmd/1` opts. Recommendation: use `10_000` ms for the headless drain
  (matching current behaviour) and keep `60_000` ms as the `stream/2` default.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Subscribe-before-start wrapper around `Tau.Session.stream/2`: stream-based drain that fixes D-004 and removes raw `receive`.
- `proposals/proposal-2.md` — `Tau.CLI.RunLoop` GenServer: OTP-compliant supervised consumer; not chosen due to residual raw `receive` in caller and heavier infrastructure.
- `proposals/proposal-3.md` — Split `drain_run_loop` into render/control; use `Task`: pure `classify_event/2` decomposition; not chosen as primary due to hand-rolled Task handshake and retained raw `receive`.
- `proposals/proposal-4.md` — Headless event behaviour (`Tau.CLI.EventHandler`): pluggable extensibility seam; not chosen as primary due to over-engineering relative to the single-callsite acceptance criterion.

## Revision history

- (revision 0 — initial)
