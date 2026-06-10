---
template_version: 1
template_name: problem
node_kind: root
depth: 0
parent: —
status: decomposed
---

# Problem: tau-coding-agent error containment is complected with feature-gate logic

## Statement

The `tau-coding-agent` subsystem uses `try/rescue/catch` blocks at four
independent sites to contain errors that should either be handled by the OTP
supervision tree or surfaced as structured `{:error, _}` returns. Each site
confounds a different pair of concerns: feature-flag access is entangled with
error silencing, tool-response shaping is entangled with optional-dependency
guarding, Port lifecycle cleanup is entangled with presence testing, and the
HTTP router has a redundant outer rescue that masks whether its inner per-handler
guards are sufficient. The result is a codebase that silently disables features,
absorbs errors that should propagate, and contains duplicated rescue patterns
whose independence from one another is unclear.

## Context

- `lib/tau/coding_agent/dispatcher.ex:384–399` — `expose_tau_context?/0` wraps
  `SettingsCache.get/0` in `rescue` + `catch`, falling back to `%{}` on any
  failure, causing the `expose_tau_context` feature to silently default to
  `true` even when the cache is misconfigured.
- `lib/tau/coding_agent/tau_context/tools.ex:215–229, 272–283, 371–379` — three
  independent `rescue`/`catch` ladders in `tau_session_status/1`,
  `safe_memory_load/1`, and `session_cwd/1`, each returning a soft
  `{"available": false}` JSON body or `nil` that is indistinguishable from a
  legitimate "feature not available" response.
- `lib/tau/coding_agents/claude_code.ex:404–414` — `close_port/1` uses a bare
  `catch _, _ -> :ok` around `Port.close/1`, relying on a prior `Port.info/1`
  check that is a separate, non-atomic operation.
- `lib/tau/coding_agent/tau_context/router.ex:76–89` — `call/2`'s outer `rescue`
  is documented as a "hard guard" for the per-handler `try/catch` blocks inside
  `dispatch/2`; the document claim is that the inner guards make it unreachable,
  but there is no structural proof.
- SPEC-CODING-AGENT §4 D-035 states: "Every public function in `tools.ex`
  catches its own errors and returns a tagged tuple. Callers in Router rely on
  this invariant." The existing implementation fulfils the letter of D-035 but
  not the spirit — errors are absorbed, not tagged.

## Complecting hypothesis

1. Feature-flag retrieval is complected with crash containment because
   `expose_tau_context?/0` conflates "the settings cache is unavailable" with
   "the setting is not configured", silencing both under the same default.
2. Tool-response shaping is complected with optional-capability guarding in
   `tools.ex` because each `rescue`/`catch` ladder maps infrastructure errors
   (unexpected process crash, bad API shape) and legitimate absences (feature
   not configured) to the same `{"available": false}` envelope, making the two
   undetectable at the call site.
3. Port close is complected with Port liveness testing because `close_port/1`
   checks `Port.info/1` and then `Port.close/1` separately, so the rescue is
   defending against a TOCTOU race its own structure created.

## Decomposition strategy

The four rescue sites are independent in location and concern; no one fix
affects another. Decompose by **rescue site** (one sub-problem per site).
The four sites are mutually exclusive by file and line range; together they
cover the entire set of OTP-non-negotiable violations flagged in the audit.
This axis is MECE: each sub-problem names exactly one site, its specific
complecting pair, and the fix surface; no site belongs to more than one
sub-problem.

## Sub-problems (filled by decomposer)

1. **settings-feature-flag-access** — `expose_tau_context?/0` in
   `dispatcher.ex` silently swallows `SettingsCache.get/0` failures and
   defaults the feature on.
2. **tool-impl-rescue-ladders** — three independent `rescue`/`catch` blocks in
   `tools.ex` absorb infrastructure errors and return them as
   `{"available": false}`, indistinguishable from legitimate absences.
3. **port-lifecycle-rescue** — `close_port/1` in `claude_code.ex` uses a bare
   `catch` around a `Port.close/1` that is defended by a non-atomic
   `Port.info/1` guard.
4. **router-outer-rescue** — the outer `rescue` in `Router.call/2` is described
   as "unreachable" given inner per-handler guards but has no structural proof
   and is therefore dead-letter coverage.

## Acceptance criterion

All four rescue sites in the audit scope are replaced with patterns that either
delegate error propagation to OTP supervision, return explicitly-tagged
structured errors distinguishable from legitimate absences, or are provably
unreachable by construction (not just by comment assertion).

## Out of scope

- Retry logic or circuit-breaker behaviour for `SettingsCache`.
- Changes to SPEC-CODING-AGENT §4 D-035's public contract.
- The `safe_start/3` and `safe_cancel/2` helpers in `dispatcher.ex` — these
  wrap adapter callbacks whose contracts include raising; rescue is appropriate
  at the behaviour boundary.
- The `spawn_drainer/2` rescue in `dispatcher.ex` — this is the
  cross-process-boundary guard the OTP non-negotiables endorse.
- `Tau.CodingAgents.Replay` — not flagged in the audit.
- Any refactoring of `Router` beyond the outer-rescue question.

## Amendment log

- (none yet)
