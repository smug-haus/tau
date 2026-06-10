---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Guard-only close — remove try/catch and Port.info/1 pre-check

## Recommendation

Replace the `try/catch`-wrapped, `Port.info/1`-guarded body of `close_port/1` with a bare
`Port.close(port)` call. The `Port.info/1` pre-check is deleted (eliminating the TOCTOU
window it introduced), the `catch _, _ -> :ok` block is deleted (allowing unexpected errors
to propagate), and the function collapses to two effective clauses: `nil`/non-port → `:ok`,
live port → `Port.close(port); :ok`. Any `ArgumentError` raised by `Port.close/1` on a
just-died port propagates to the caller, making the event visible rather than silently
erased; since both current callers (`port_done/1` and the cancel branch in `port_next/2`)
run under OTP supervision, propagation is the correct recovery path.

## Selected from

- **Chosen:** `proposals/proposal-1.md` — guard-only
- **Why chosen:** Proposal 1 is the only proposal that satisfies the acceptance criterion
  without qualification: no `try/catch`, no `try/rescue`, no TOCTOU window, unexpected
  errors propagate. Proposal 2 retains `try/rescue` and is self-disqualified by the
  criterion's literal wording. Proposal 3 satisfies the criterion but introduces a
  `receive` block into a synchronous function (mailbox-steal risk in GenServer callbacks)
  and a magic `after 5` timeout for a problem whose entire solution is 3 lines; the
  added complexity is not warranted by the risk profile. Proposal 4 deletes `close_port/1`
  and shifts to a subprocess-signal model, but the subprocess termination protocol is
  unverified, the cancel-path removal risks OS subprocess accumulation, and `port_done/1`'s
  replacement re-introduces a `Port.info/1` TOCTOU of its own — scope and risk both exceed
  what the problem calls for. Proposal 1 is the minimal decomplecting move: it removes both
  halves of the tangled structure (guard + catch) in one step, leaves the common path
  unchanged, and lets unexpected errors surface.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Deep | Low | Low | Easy |
| 2 | No (fails literal AC) | Substantial | Low | Low | Easy |
| 3 | Yes | Substantial | Medium | Medium | Moderate |
| 4 | Partially | Substantial | Medium | Medium | Moderate |

## What changes

- `lib/tau/coding_agents/claude_code.ex` — replace the single `close_port/1` clause (lines
  402–416) with:

  ```elixir
  defp close_port(nil), do: :ok

  defp close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  end

  defp close_port(_), do: :ok
  ```

  Net: ~9 lines removed, 8 lines added (3 clauses). No call-site changes required.

## What does not change

- `port_done/1` and the cancel branch in `port_next/2` — both discard the return from
  `close_port/1` and continue to do so.
- The `:ok` return contract for the common (live-port) path.
- All other functions in `claude_code.ex`.
- All sibling sub-problems (settings-feature-flag-access, tool-impl-rescue-ladders,
  router-outer-rescue) — entirely separate.

## Migration sketch

Single-step: replace the function body in `lib/tau/coding_agents/claude_code.ex`. Before
merging, audit both call sites (`port_done/1` and `port_next/2` cancel branch) to confirm
neither wraps `close_port/1` in a rescue that would re-introduce silent swallowing. If any
existing test asserts `:ok` on a double-close path (i.e. tests that relied on the catch),
update to test only the single-close path or accept `ArgumentError` propagation. No other
files, modules, or tests need to change.

## Open questions

- **Call-site execution context:** Both call sites appear to run in a Task or process
  spawned for streaming, not in a `GenServer.handle_*` callback. If that assumption is
  wrong and either runs in a GenServer callback, an uncaught `ArgumentError` on double-close
  would crash the callback — acceptable under OTP non-negotiable rule 7, but worth
  confirming explicitly.
- **Stream `after_fun` behaviour on ArgumentError:** If `port_done/1` is the `after_fun`
  of a `Stream.resource/3`, an uncaught `ArgumentError` there may have platform-specific
  behaviour (stream teardown abort vs. propagation). If the stream infrastructure silences
  it, the improvement is real but the observable signal is still muted. This should be
  verified against the stream usage in `port_next/2`.
- **Existing tests for double-close:** The proposals note tests may assert `:ok` on
  double-close (relying on the old catch). These tests should be found and updated; no
  new test surface is needed beyond that.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — guard-only: remove Port.info/1 pre-check and bare catch
- `proposals/proposal-2.md` — tagged-tuple: targeted rescue ArgumentError (fails literal AC)
- `proposals/proposal-3.md` — monitor/receive: atomic liveness via Port.monitor (over-engineered)
- `proposals/proposal-4.md` — push close to owner: delete close_port/1, signal subprocess (low confidence, scope creep)

## Revision history

- (revision 0 — initial)
