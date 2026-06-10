---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md]
selection_method: hybrid
revision: 1
---

# Solution: Delete wildcard rescue/catch; targeted catch + rescue at the command boundary; amend NN #7

## Recommendation

Delete `safe_list/0` and `safe_reload/0` from `Tau.CLI.Extensions` and
`Tau.CLI.MCP`. Replace them with a targeted `try` block at the command-handler
boundary that uses BOTH `rescue _ -> {stderr; exit_code}` (for non-exit
exceptions named by problem.md's AC) AND `catch :exit, {:noproc, _} -> ...` /
`catch :exit, reason -> ...` (targeted, not wildcard). The `case`-on-result
structure of `reload/1` is collapsed: the callees (`Tau.Extensions.Loader.reload_all/0`
and `Tau.MCP.Reconciler.reload/0`) are both `GenServer.cast`, so they return
only `:ok` — the existing `{:error, reason}` application-level arm is dead
(reachable today only through the swallow itself) and is removed. Exit codes:
`list/1` and `status/1` widen their `@spec` from `0` to `0 | 1` and return `1`
on failure; `reload/1` keeps its existing `@spec 0 | 2` and returns `2` on
failure. The NN #7 carve-out the targeted catch relies on is made explicit in
the same PR family via a documented amendment to
`.claude/rules/otp-non-negotiables.md` (precedent: `lib/tau/providers/rate_limiter.ex:86`).

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` and `proposals/proposal-2.md`
- **Why chosen:** Proposal 1's core move — delete the private rescue shims —
  is the load-bearing decomplecting step. Its weakness, that diagnostic quality
  becomes hostage to a `Tau.CLI.main/1` top-level handler that does not exist
  today (`lib/tau/cli.ex:69–136` has no top-level rescue), is closed by
  proposal 2's insight: a targeted catch at the command-handler boundary
  produces per-command diagnostics without a new abstraction. The hybrid takes
  proposal 1's deletion of `safe_list/0` / `safe_reload/0`, takes proposal 2's
  targeted `catch :exit, {:noproc, _}` shape, and additionally adds a
  `rescue _` arm to cover non-exit exceptions (which neither proposal covered
  in its sketch but problem.md's AC explicitly names). Proposals 3 and 4 were
  rejected: proposal 3's `ProcessQuery` behaviour adds structural weight
  disproportionate to the problem scope and carries a TOCTOU race; proposal 4's
  API-breaking `command_result()` return type is out of scope for a
  rescue-removal fix.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Partially | Deep | Low | Medium | Easy |
| 2 | Partially | Substantial | Medium | Low | Easy |
| 3 | Partially | Substantial | High | Medium | Easy |
| 4 | Yes | Substantial | High | Medium | Hard |

Proposals 1 and 2 each score "Partially" on fit as written, because each leaves
one branch of the AC uncovered (proposal 1: per-command context lost on the
top-level handler path that does not exist; proposal 2: non-exit exceptions
uncovered, dead `{:error, _}` arm preserved). The hybrid closes both gaps by
combining proposal 1's deletion with proposal 2's targeted catch AND a `rescue
_` arm for non-exit exceptions. Proposal 4 fits the AC outright but at the cost
of an API-breaking `command_result()` return-type change — disproportionate to
this PR.

## What changes

- `lib/tau/cli/extensions.ex` — delete `safe_list/0` (lines 67–73) and
  `safe_reload/0` (lines 75–81). In `list/1`, wrap the direct
  `Tau.Extensions.Loader.list()` call in a `try` block with:
    - normal body: bind the result to `entries`, run existing render logic,
      return `0`;
    - `rescue e -> IO.puts(:stderr, "extensions list failed: " <> Exception.message(e)); 1`;
    - `catch :exit, {:noproc, _} -> IO.puts(:stderr, "extensions list: Extensions.Loader is not running"); 1`;
    - `catch :exit, reason -> IO.puts(:stderr, "extensions list: process exit: " <> inspect(reason)); 1`.
  In `reload/1`, wrap the direct `Tau.Extensions.Loader.reload_all()` call in
  the same shape: normal body returns `0` after the success print; the prior
  `case … {:error, reason} → … 2 end` is REMOVED (the arm is dead because
  `reload_all/0` is `GenServer.cast` returning `:ok` only). The
  `catch`/`rescue` arms return `2` (preserving `@spec 0 | 2`) with the existing
  "extensions reload failed: …" stderr prefix repurposed for process-level
  errors.
- `lib/tau/cli/mcp.ex` — identical change in shape: delete `safe_list/0`
  (lines 98–104) and `safe_reload/0` (lines 106–112). Apply the same targeted
  `try/rescue/catch` block in `list/1`, `status/1`, and `reload/1`. `list/1`
  and `status/1` return `1` on failure (widen `@spec` to `0 | 1`); `reload/1`
  returns `2` on failure (keep `@spec 0 | 2`); the dead `{:error, reason}` arm
  in `reload/1` is REMOVED for the same reason as Extensions
  (`Tau.MCP.Reconciler.reload/0` is also `GenServer.cast` returning `:ok`).
- `@spec` updates in same PR:
    - `Tau.CLI.Extensions.list/1` — `@spec list(opts()) :: 0` → `0 | 1`;
    - `Tau.CLI.MCP.list/1` and `Tau.CLI.MCP.status/1` — same widening
      (currently `@spec :: 0`);
    - `Tau.CLI.Extensions.reload/1` and `Tau.CLI.MCP.reload/1` — `@spec ::
      0 | 2` unchanged (the `2` arm is repurposed from "application reload
      error" to "process unavailable / unexpected exception").
- `.claude/rules/otp-non-negotiables.md` — amend rule #7 in the SAME PR family
  to add an explicit carve-out: "MUST NOT wildcard-catch `:exit`. A *targeted*
  `catch :exit, {:noproc, _}` (or other named exit-reason shape) AT A CLI /
  TUI command boundary is permitted as an OTP-recommended availability escape
  hatch; the precedent is `lib/tau/providers/rate_limiter.ex:86`." The
  amendment makes the existing `rate_limiter.ex` precedent compliant under
  literal reading and makes this PR's targeted catches compliant.
- No other files change. `lib/tau/cli.ex` dispatch table (lines 95–113) is
  unaffected: public function arities are unchanged and the `halt/1` sink
  (`lib/tau/cli.ex:816–817`) accepts any integer the handlers return.

## What does not change

- Public function arities: `list/1`, `reload/1`, `status/1` all continue to
  accept the same `opts` and return integer exit codes (now in the widened
  `@spec` ranges named above).
- `lib/tau/cli.ex` dispatch table — no callsite changes required.
- `Tau.Extensions.Loader.list/0`, `Tau.Extensions.Loader.reload_all/0`,
  `Tau.MCP.Reconciler.list/0`, and `Tau.MCP.Reconciler.reload/0` interfaces —
  untouched.
- The cast-based asynchronous reload semantics: `tau extensions reload` and
  `tau mcp reload` still return `0` as soon as the cast is delivered, even if
  the actual reload work fails asynchronously. Surfacing async-reload errors
  requires changing the callee API (cast → call, or a feedback channel) and is
  out of scope here (flagged for the parent in Open questions).
- The existing rescue/catch sites outside the four named functions (per
  problem.md's "Out of scope" section): `safe_to_atom/1`, `validate/1` in
  `Tau.CLI.Config`, `drain_run_loop/2`, and the rate-limiter's own targeted
  catch.

## Migration sketch

Single PR, three files. (1) `lib/tau/cli/extensions.ex`: delete the two `defp`
helpers; replace `list/1`'s body with a `try`-wrapped direct call carrying the
`rescue _` and two `catch :exit, …` arms; replace `reload/1`'s body the same
way, REMOVING the prior `case` and its `{:error, _}` arm entirely (the callee
returns `:ok` only); update the `@spec` on `list/1` from `0` to `0 | 1`.
(2) `lib/tau/cli/mcp.ex`: mirror exactly in `list/1`, `status/1`, and
`reload/1`; update `@spec` on `list/1` and `status/1` from `0` to `0 | 1`.
(3) `.claude/rules/otp-non-negotiables.md`: append the targeted-form carve-out
to rule #7 with the `rate_limiter.ex:86` precedent. Run `mix compile
--warnings-as-errors` (Dialyzer will confirm the `@spec` widening); run `mix
test` and update any test asserting `list/1 == 0` when the supervisor is down
to assert `1` plus the corresponding stderr line. The PR description must
explicitly link the NN #7 amendment commit to the rescue-removal commits so a
single reviewer sees the carve-out at the same time as the new catches.

## Open questions

- `Tau.CLI.main/1` has no top-level rescue (verified at
  `lib/tau/cli.ex:69–136`). The hybrid's per-handler `rescue _` closes the
  in-scope AC for the four named commands, but other CLI handlers (e.g.
  `config_get`, `init_cmd`, `tui_cmd`) remain exposed to raw BEAM crash dumps
  on uncaught exceptions. Flagged for the parent as a sibling sub-problem
  ("`main/1` lacks a top-level safety net") — out of scope here.
- `Tau.Extensions.Loader.reload_all/0` and `Tau.MCP.Reconciler.reload/0` are
  `GenServer.cast` and therefore fire-and-forget. `tau extensions reload`
  returns `0` on cast delivery regardless of whether the asynchronous reload
  succeeds. Surfacing async-reload errors would require either converting the
  callees to `GenServer.call` (changes their concurrency semantics — a
  long-running reload would block the caller) or adding a result-feedback
  channel (telemetry + a synchronous follow-up query). Both are out of scope
  for the rescue-removal PR; flagged for the parent.
- If the NN #7 amendment is rejected during PR review, the fallback is
  proposal 1's deletion-only form PLUS a top-level rescue in `Tau.CLI.main/1`
  (added in the same PR). That pivot keeps the rescue-removal intact while
  routing exit-translation through `main/1` rather than a per-handler catch.
  Pre-deciding the fallback bounds the PR's risk.
- Why NOT a `Task.async + Task.yield`-based "convert crash to `{:error, _}`"
  pattern? Two reasons: (a) `Task.yield` itself relies on monitored exits and
  the monitor's `:DOWN` message — under the literal NN #7 reading, that is
  *also* a process-boundary crash interception, just spelled differently. The
  carve-out NN amendment is needed either way. (b) Wrapping every CLI call in
  a `Task` triples the process count for the simplest operations and is
  disproportionate to the four affected functions; the targeted `catch :exit`
  is mechanically smaller and matches the existing precedent.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Delete safe_list/safe_reload; let calls crash to top-level handler
- `proposals/proposal-2.md` — Replace rescue/catch with targeted GenServer.call boundary + tagged tuples
- `proposals/proposal-3.md` — Introduce Tau.CLI.ProcessQuery behaviour + pre-flight whereis check (rejected: disproportionate structural cost, TOCTOU race)
- `proposals/proposal-4.md` — Lift error signals to command boundary via `command_result()` return type (rejected: API-breaking, out of scope)

## Revision history

- revision 0 — initial hybrid of proposal 1 + proposal 2; placed targeted
  `catch :exit` at the command-handler boundary, kept the `case` structure in
  `reload/1`, asserted NN #7's wildcard-only reading as settled.
- revision 1 — validator falsified four points; this revision corrects all
  four:
    1. **Dead error arm (claim 4).** Confirmed `Tau.Extensions.Loader.reload_all/0`
       (`lib/tau/extensions/loader.ex:65`) and `Tau.MCP.Reconciler.reload/0`
       (`lib/tau/mcp/reconciler.ex:44`) are `GenServer.cast`, returning `:ok`
       only. The `{:error, reason}` arm in the current `reload/1` is reachable
       today only via the `safe_reload/0` rescue itself. Removed: the new
       `reload/1` body has no `case` and no `{:error, _}` arm. (Switching the
       callees to `GenServer.call` was considered and rejected — it changes
       async concurrency semantics for the rescue-removal PR's scope.)
    2. **Exit-code/spec contradiction (claim 5).** Chosen explicitly: keep
       `@spec reload(opts()) :: 0 | 2` and use `2` for the rescue/catch arms
       in `reload/1`; widen `@spec list(opts()) :: 0` → `0 | 1` for
       `list/1` / `status/1` and use `1`. No `System.halt(1)` anywhere; each
       handler returns its integer to `halt/1` in `lib/tau/cli.ex` as before.
    3. **Uncovered non-exit exceptions (claim 3).** Added `rescue _ ->
       stderr; exit_code` to each handler's `try` block. The four AC failure
       modes (`:noproc`, other process exit, non-exit exception, and the
       `:timeout` shape covered by the fallthrough `catch :exit, reason`) all
       produce non-zero exit + stderr diagnostic.
    4. **NN #7 wildcard carve-out (claim 6).** Acknowledged that NN #7 as
       authored has no "wildcard" qualifier — the targeted-form carve-out the
       prior solution asserted is not established. Adopted the validator's
       preferred path (option a): amend NN #7 in the same PR to add an
       explicit carve-out for targeted `catch :exit, {:noproc, _}` at CLI/TUI
       command boundaries, citing the existing `rate_limiter.ex:86` precedent.
       Pivoting to a `Task.async + Task.yield` pattern was considered and
       rejected (see Open questions): `Task.yield`'s monitored-`:DOWN`
       mechanism is itself a process-boundary crash interception under the
       literal reading, so the amendment is needed either way; the targeted
       catch is mechanically smaller and matches the existing precedent. The
       fallback if the NN amendment is rejected during PR review (pure
       deletion + top-level `main/1` rescue) is also stated explicitly in
       Open questions.
