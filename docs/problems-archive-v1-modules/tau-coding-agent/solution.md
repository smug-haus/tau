---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from:
  - subproblems/settings-feature-flag-access/solution.md
  - subproblems/tool-impl-rescue-ladders/solution.md
  - subproblems/port-lifecycle-rescue/solution.md
  - subproblems/router-outer-rescue/solution.md
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Site-specific decomplecting of the four tau-coding-agent rescue ladders

## Recommendation

Apply four independent, site-specific fixes — each chosen to match its rescue
site's harm profile — to satisfy the module-level acceptance criterion that
every flagged `try/rescue/catch` either delegates to OTP, returns an explicitly
tagged structured error, or is provably unreachable. The four fixes share no
shared module, behaviour, or new abstraction; they intentionally decline a
unified "rescue policy" module because the four sites have orthogonal complecting
pairs and aggregating them would re-complect what the decomposition separated.
Concretely: (1) convert `expose_tau_context?/0` to a tagged-tuple `fetch_*`
plus pattern-matched caller (decomplect feature-flag retrieval from crash
containment); (2) split `tools.ex` asymmetrically — delete `session_cwd/1`'s
rescue (let it crash; OTP restarts), and on the two soft-fail helpers add an
additive `"result_kind": "infrastructure_error"` field plus a `[:tau, :tools,
:infrastructure_error]` telemetry event (decomplect infrastructure errors from
legitimate absences while preserving the subprocess-tolerant envelope);
(3) collapse `close_port/1` to a guard-only form (`nil`/non-port → `:ok`;
live port → `Port.close(port); :ok`) — eliminate the TOCTOU window and let
`ArgumentError` propagate to OTP; (4) harden `Router.load_state/1` with its
own intra-function rescue and retain the outer `call/2` rescue as an
explicitly annotated, property-tested backstop. The four fixes land
independently with no inter-fix ordering constraint.

## Selected from

- **Synthesised from:** child solutions at
  `subproblems/settings-feature-flag-access/solution.md`,
  `subproblems/tool-impl-rescue-ladders/solution.md`,
  `subproblems/port-lifecycle-rescue/solution.md`,
  `subproblems/router-outer-rescue/solution.md`.
- **Composition rationale:** the four child solutions compose by **direct
  composition** with **no inter-child interface**. The decomposition strategy
  in `problem.md` partitioned the work by rescue site (MECE: each site lives
  in exactly one file/line range, each addresses exactly one complecting pair);
  the validated child solutions inherit that independence. Each child fixes one
  site in one file, with no callers in any other child's file. Concretely:
  - settings-feature-flag-access touches only `dispatcher.ex` (private
    functions); no other child reads or writes it.
  - tool-impl-rescue-ladders touches `tools.ex` (and one telemetry-handler
    attachment in `application.ex` or `otel_reporter.ex`); none of the other
    children touches `tools.ex` or the telemetry namespace.
  - port-lifecycle-rescue touches `claude_code.ex` only (one private function,
    `close_port/1`); no other child touches the claude-code adapter.
  - router-outer-rescue touches `router.ex` only (plus a new test file); no
    other child touches the router.

  There is **no conflict** between the recommendations: none of the four
  solutions proposes a shared module, a behaviour change, or a contract revision
  that would constrain a sibling's implementation. There is also **no gap**:
  the four sites together exhaust the audit's scope (the problem's "What this
  rule forbids" enumeration cites exactly these four sites; the out-of-scope
  list explicitly carves out `safe_start/3`, `safe_cancel/2`, `spawn_drainer/2`,
  and `Replay`).

  The synthesis declines to introduce a unifying "tagged-result"
  module/behaviour even though three of the four solutions adopt tagged-tuple
  or tagged-field returns. The harm profile, return shape, and call-site
  pattern differ at each site: dispatcher returns `{:ok, bool} | {:error,
  :cache_unavailable}`; tools.ex two-of-three add an additive wire-format
  field on a JSON envelope; close_port returns `:ok` and propagates; router
  retains the rescue as an explicit backstop. A common abstraction would re-
  complect them. Composition, not aggregation (Hickey-aligned).

## What changes

Per child solution, summarised at file granularity:

- **`lib/tau/coding_agent/dispatcher.ex`** (settings-feature-flag-access):
  - Rename `expose_tau_context?/0` → `fetch_expose_tau_context/0`; change
    return to `{:ok, boolean()} | {:error, :cache_unavailable}`.
  - The existing `rescue`/`catch` ladder returns `{:error, :cache_unavailable}`
    in place of `%{}`.
  - Rewrite `maybe_start_tau_context/1` to pattern-match all three outcomes;
    emit `[:tau, :coding_agent, :tau_context, :settings_unavailable]` telemetry
    on the error branch (fail-closed: skip TauContext start).
  - Extract `do_start_tau_context/1` (mechanical separation; no logic change).

- **`lib/tau/coding_agent/tau_context/tools.ex`** (tool-impl-rescue-ladders):
  - `session_cwd/1`: delete the `rescue`/`catch` block entirely; extend the
    `case` to handle `{:error, :not_found}` → `nil` and `{:error, _}` → `nil`
    explicitly. Any unexpected non-`:ok`/non-`:error` return raises
    `CaseClauseError` and propagates to the supervisor.
  - `tau_session_status/1`: keep `rescue`/`catch`; add `"result_kind" =>
    "infrastructure_error"` to the returned map; emit
    `:telemetry.execute([:tau, :tools, :infrastructure_error], ...)` before
    returning.
  - `safe_memory_load/1`: keep `rescue`/`catch`; emit the same telemetry event.
  - `tau_memory_query/2` (caller of `safe_memory_load/1`): on `{:error,
    reason}` produce `%{"available" => false, "result_kind" =>
    "infrastructure_error", "reason" => reason}` so the wire format carries
    the distinguishing field.

- **`lib/tau/application.ex`** (or `lib/tau/otel_reporter.ex`):
  attach a telemetry handler for `[:tau, :tools, :infrastructure_error]` that
  emits a `Logger.warning` so the event does not fire into a vacuum.

- **`lib/tau/coding_agents/claude_code.ex`** (port-lifecycle-rescue):
  replace the single `close_port/1` clause (lines 402–416) with three guard
  clauses:

  ```elixir
  defp close_port(nil), do: :ok
  defp close_port(port) when is_port(port), do: (Port.close(port); :ok)
  defp close_port(_), do: :ok
  ```

  Delete the `Port.info/1` pre-check and the `catch _, _ -> :ok` ladder. Net
  ~9 lines removed, ~8 added. `ArgumentError` from a just-died port propagates
  to the OTP-supervised caller.

- **`lib/tau/coding_agent/tau_context/router.ex`** (router-outer-rescue):
  - Add `@safe_default` module attribute holding the default state map.
  - Rewrite `load_state/1` with its own intra-function `rescue`: catch
    exceptions from `:persistent_term.get/2`, log via `Logger.error/1` with
    exception + stacktrace, return `@safe_default`.
  - Rewrite the outer `call/2` `rescue`: keep the rescue body; replace the
    misleading "should be unreachable" comment with an `@outer_rescue_scope`
    annotation that names the paths covered by inner guards and states why the
    backstop is retained (defence-in-depth against a future fallible top-level
    branch added without its own guard).

- **`test/tau/coding_agent/tau_context/router_outer_rescue_test.exs`** (new
  file): unit test for `load_state/1`'s rescue path; integration test verifying
  poisoned `state_ref` returns 401, not 500; StreamData property test verifying
  `Router.call/2` never raises.

## What does not change

- `lib/tau/settings/cache.ex` — `SettingsCache` is untouched.
- `Tau.CodingAgent.Supervisor`, supervision-tree topology, restart strategies.
- SPEC-CODING-AGENT §4 D-035 public contract: every public function in
  `tools.ex` still returns `{:ok, String.t()}` to its caller. The
  `"result_kind"` field is **additive** in the JSON wire format; existing
  subprocess consumers that do not inspect it are unaffected.
- The `safe_start/3`, `safe_cancel/2`, and `spawn_drainer/2` rescue blocks in
  `dispatcher.ex` (out of scope per `problem.md`).
- `Tau.CodingAgents.Replay` (not flagged).
- `dispatch/2`'s `rescue`/`catch` and `handle_mcp/2`'s `with`-else pipeline in
  `router.ex` — both retained as-is.
- The MCP wire protocol's existing fields, auth logic, and HTTP routing table.
- `port_done/1` and the cancel branch in `port_next/2` — both still discard
  `close_port/1`'s return.
- `:persistent_term` read semantics and performance.
- The legitimate-absence return shapes in `tools.ex` (`:not_found`, unloaded
  `MemoryLoader`, `nil` session_id) — unchanged.
- No new modules, no new behaviours, no shared "rescue policy" abstraction.

## Migration sketch

The four fixes have **no inter-dependency** and may land as four independent
PRs in any order, or as a single combined PR. The factory-loop parallelism
test (`.claude/rules/factory-loop.md` §"Parallel execution") clears all five
clauses: disjoint files, disjoint codepoints (each fix touches a distinct
private function), no shared SPEC amendment, no shared `$HOME`-namespace
resource. Recommended sequencing if landed serially (lowest-risk first, easiest
to revert): (1) `close_port/1` guard-only — smallest diff, smallest surface;
(2) `dispatcher.ex` tagged-tuple — single private call chain, no public-API
change; (3) `router.ex` `load_state/1` hardening + annotated backstop + new
test file; (4) `tools.ex` asymmetric fix + telemetry-handler attachment in
`application.ex`. Each fix re-runs the existing test baseline; the only new
test surface is the router file in step 3 and a `session_cwd/1` crash-
propagation property test in step 4 (per child solutions).

Per `spec-before-code.md`: `tools.ex` lives in SPEC-CODING-AGENT Appendix B,
so step 4's PR description must cite D-035 and note that `"result_kind"` is an
additive wire-format field; a §3 amendment to SPEC-CODING-AGENT documenting
the new field is recommended by the child solution and should land in the same
PR (per the rule). The other three steps do not modify SPEC'd boundary
contracts; `router.ex` and `claude_code.ex` are not in any SPEC's Appendix B
scope, and `dispatcher.ex`'s change is to a private function whose tagged-
tuple shape is internal.

## Open questions

Module-level questions only; per-site questions remain in the child solutions.

- **No shared abstraction:** the synthesis declines to introduce a common
  tagged-result module. The validator should confirm this is sound — if a
  pattern emerges across the four sites that warrants extraction (e.g. a
  shared `Tau.CodingAgent.Result` module), a follow-up problem can be filed,
  but the current evidence does not support pre-extracting one.
- **Telemetry namespace coherence:** two new telemetry events are introduced
  by separate child fixes — `[:tau, :coding_agent, :tau_context,
  :settings_unavailable]` (dispatcher) and `[:tau, :tools,
  :infrastructure_error]` (tools). Both follow the `[:tau, ...]` convention
  (OTP non-negotiable #5). The validator should confirm no collision with
  existing events and that the second event's handler is attached early
  enough that no `tools.ex` invocation can fire before it.
- **D-035 spirit-vs-letter:** `problem.md`'s context notes that the existing
  implementation fulfils D-035's letter but not its spirit. The synthesis
  satisfies the letter at every site and improves the spirit at three of four
  (settings, port, tools `session_cwd/1`). The remaining soft-fail sites in
  `tools.ex` now emit telemetry and carry `result_kind`, which is the
  decomplecting the spirit demands. The validator should confirm this is the
  correct read of D-035.
- **Per-site open questions** (verbatim from child solutions, not duplicated
  here): see each `subproblems/<sub>/solution.md` §"Open questions".

## Linked sub-problems / proposals

- `subproblems/settings-feature-flag-access/` → "Tagged-result return for
  expose_tau_context?/0: rename to `fetch_expose_tau_context/0` returning
  `{:ok, boolean()} | {:error, :cache_unavailable}`; pattern-match all three
  cases in the caller; emit `:settings_unavailable` telemetry on the error
  branch (fail-closed)."
- `subproblems/tool-impl-rescue-ladders/` → "Asymmetric rescue removal: delete
  `session_cwd/1`'s rescue (let it crash; OTP restarts); on
  `tau_session_status/1` and `safe_memory_load/1` retain rescue but add
  `\"result_kind\": \"infrastructure_error\"` and `[:tau, :tools,
  :infrastructure_error]` telemetry."
- `subproblems/port-lifecycle-rescue/` → "Guard-only close: replace
  `close_port/1` with three pattern clauses; delete `Port.info/1` pre-check
  and `catch` ladder; let `ArgumentError` propagate to OTP."
- `subproblems/router-outer-rescue/` → "Harden `load_state/1` with its own
  rescue + safe-default + log; retain `call/2`'s outer rescue as an
  explicitly annotated, property-tested defence-in-depth backstop (acceptance-
  criterion option (b))."

## Combined acceptance criteria

The parent's single acceptance criterion (all four rescue sites replaced
with delegate-to-OTP, tagged-structured-error, or provably-unreachable-by-
construction patterns) is satisfied as follows, per site:

1. **dispatcher.ex `expose_tau_context?/0`** → **tagged structured error**:
   `{:error, :cache_unavailable}` is distinguishable from `{:ok, false}` and
   `{:ok, true}`; caller dispatches all three.
2. **tools.ex `session_cwd/1`** → **delegate to OTP**: rescue removed; crashes
   propagate to the supervised MCP process.
3. **tools.ex `tau_session_status/1` + `safe_memory_load/1`** → **tagged
   structured error in the wire format**: `"result_kind":
   "infrastructure_error"` is distinguishable from legitimate-absence
   `"available": false` responses (which carry no `result_kind`); paired with
   telemetry for production observability.
4. **claude_code.ex `close_port/1`** → **delegate to OTP**: `catch` removed;
   `ArgumentError` propagates to the supervised caller.
5. **router.ex `call/2` outer rescue** → **provably narrowed**: `load_state/1`
   is now self-guarding (the one previously-fallible callee), the outer rescue
   is retained as an annotated backstop named in `@outer_rescue_scope`, and a
   StreamData property test verifies `call/2` never raises (closing the proof
   gap the parent problem identified).

## Revision history

- (revision 0 — initial)
