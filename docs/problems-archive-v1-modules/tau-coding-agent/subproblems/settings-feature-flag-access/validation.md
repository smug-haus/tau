---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Tagged-result return for expose_tau_context?/0

## Overview

The solution proposes renaming `expose_tau_context?/0` to
`fetch_expose_tau_context/0`, changing its return type to `{:ok, boolean()} |
{:error, :cache_unavailable}`, and rewriting `maybe_start_tau_context/1` to
pattern-match on all three outcomes — with fail-closed telemetry for the
`:cache_unavailable` case. Five claims are extracted: (1) the rename satisfies
the acceptance criterion; (2) the change is confined to `dispatcher.ex`; (3)
`SettingsCache.get/0` can raise when the process is absent, so the
`rescue`/`catch` arms are load-bearing; (4) the external public API is
unchanged; (5) the telemetry event follows the existing namespace convention.
Falsification strategies: dependency check (claims 1, 3), counter-example
construction (claim 2), edge-case enumeration (claims 4, 5). Claim 3 is
**partially falsified**: `SettingsCache.get/0` reads from `:persistent_term`
with a default and never raises; the `rescue`/`catch` arms in the proposed
solution are dead code. The qualifier on claim 3 requires narrowing. No
revision is triggered because the solution's correctness survives the
narrowing: the tagged-tuple form still satisfies the acceptance criterion under
the actual SettingsCache contract, and retaining dead-code guard arms is safe
(conservative), not harmful.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found
it difficult to generate Toulmin structures, and their structures varied greatly
even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to counter
that variance.

---

### Claim 1: Renaming expose_tau_context?/0 to fetch_expose_tau_context/0 and returning {ok, boolean()} | {error, cache_unavailable} satisfies the acceptance criterion

- **Claim (C):** "`expose_tau_context?/0` returns a value that the caller can
  use to distinguish 'setting is on', 'setting is off', and 'cache
  unavailable'; callers in `maybe_start_tau_context/1` handle each case
  explicitly without conflating cache failures with deliberate configuration."
  (problem.md Acceptance criterion)
- **Grounds (G):** The solution's `maybe_start_tau_context/1` rewrite
  pattern-matches on all three tuple shapes: `{:ok, true}` → start context,
  `{:ok, false}` → skip, `{:error, :cache_unavailable}` → telemetry + skip.
  All three branches are distinct (solution.md §What changes; proposal-1.md
  sketch lines 58–73). The current `dispatcher.ex:344–371` uses `if
  expose_tau_context?()`, which is binary and conflates the third case with
  the second.
- **Warrant (W):** A tagged-tuple return type structurally encodes the three
  distinguishable outcomes at the type level; the caller's exhaustive
  pattern-match on the tag enforces explicit handling. An `if` over a boolean
  cannot represent a third non-boolean outcome. (Elixir convention: `fetch_*`
  returns `{:ok, v} | {:error, reason}`; `Map.fetch/2`, `Keyword.fetch/2`.)
- **Qualifier (Q):** Holds for the private call chain within `dispatcher.ex`.
  The acceptance criterion does not require the error to be visible to external
  callers (all functions are private).
- **Rebuttal (R):** If the `{:error, :cache_unavailable}` branch is never
  reachable at runtime (see Claim 3), the structural distinction is present in
  code but untriggerable in production, meaning the observability gain is
  latent. The criterion would still be formally satisfied because the code path
  exists and tests can exercise it via mocking.
- **Backing (B):** problem.md §Acceptance criterion; OTP non-negotiable rule 7
  ("Let it crash; supervise; restart" — tagged-tuple return is the idiomatic
  non-crash alternative at private-function boundaries); SPEC-CODING-AGENT §4
  (expose_tau_context semantics).

#### Falsification attempt for claim 1

- **Strategy:** Dependency check — verify that the acceptance criterion's
  three-way distinguishability requirement is achievable with the proposed
  return type under the actual SettingsCache contract.
- **Attempt:** `SettingsCache.get/0` returns `%{}` as default (never raises;
  see Claim 3 below). This means `{:error, :cache_unavailable}` is never
  returned at runtime. The caller's `{:error, :cache_unavailable}` branch is
  therefore structurally present but unreachable under normal operation. The
  acceptance criterion says the caller "can use" the return to distinguish the
  three cases — it does not say the third case is observable in production. A
  test that mocks `SettingsCache.get/0` to raise can exercise the third branch.
- **Outcome:** Withstood — the criterion is formal (structural distinguishability),
  and the proposed type satisfies it. The dead branch does not falsify
  satisfying the criterion.
- **Action:** None. Note the rebuttal above in Outstanding Doubts.

---

### Claim 2: All changes are confined to dispatcher.ex; no public API is changed

- **Claim (C):** "All changes are in a single private call chain, so the
  migration is a single atomic commit." (solution.md §Migration sketch)
- **Grounds (G):** `expose_tau_context?/0` is a `defp` (private) at
  `dispatcher.ex:384`. `maybe_start_tau_context/1` is a `defp` at
  `dispatcher.ex:344`. Neither is in the module's `@doc`-annotated public
  surface. `lib/tau/settings/cache.ex` is explicitly listed as unchanged.
  `Tau.CodingAgent.Supervisor` and `lib/tau/application.ex` are explicitly
  listed as unchanged (solution.md §What does not change).
- **Warrant (W):** Private functions in Elixir modules (`defp`) are not
  accessible outside the module; renaming or changing their signature cannot
  break any external caller. The OTP non-negotiable rule 8 ("Pure functions
  are the default; processes are the exception") supports confining this change
  to pure, private logic.
- **Qualifier (Q):** Holds provided no other module in `lib/tau/` calls
  `expose_tau_context?/0` or `maybe_start_tau_context/1` via a macro or
  `:erlang.apply/3` dynamic dispatch, which would bypass Elixir's private
  enforcement.
- **Rebuttal (R):** Elixir's `defp` does not prevent `:erlang.apply/3` dynamic
  calls from other modules, though this would be an anti-pattern. A grep
  confirms no such call exists in this repo (see Falsification attempt).
- **Backing (B):** Elixir language spec on module visibility; solution.md §What
  does not change.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — search for cross-module
  references to the private functions.
- **Attempt:** `grep -rn "expose_tau_context\|maybe_start_tau_context"
  lib/ test/` (executed above). Results: only `dispatcher.ex` at lines 338,
  345, 384, 397, plus `tau_context.ex:6` (a `@moduledoc` mention, not a call).
  No cross-module call site found.
- **Outcome:** Withstood — no external caller found; the scope claim holds.
- **Action:** None.

---

### Claim 3: The rescue/catch arms are load-bearing because SettingsCache.get/0 can raise when the cache process is absent

- **Claim (C):** "SettingsCache failure mode: Proposal 1 notes with medium
  confidence that `SettingsCache.get/0` actually raises (rather than returning
  `{:error, _}`) when the process is absent." (solution.md §Open questions Q1)
  The solution preserves `rescue`/`catch` in the proposed `fetch_expose_tau_context/0`
  on this assumption. The proposal-1.md sketch also retains `rescue`/`catch`.
- **Grounds (G):** `lib/tau/settings/cache.ex:28`: `def get, do:
  :persistent_term.get(@persistent_key, %{})`. `:persistent_term.get/2` with a
  default never raises — it returns the default when the key is absent
  (Erlang/OTP `:persistent_term` module: `get(Key, Default)` always returns
  `Default` when `Key` is not set). The `SettingsCache` GenServer's `init/1`
  calls `:persistent_term.put(@persistent_key, settings)` at startup
  (`cache.ex:32–34`), so the key is populated only after the GenServer starts.
  Before that, `get/0` returns `%{}` via the default, not a raise.
- **Warrant (W):** `:persistent_term.get/2` is a read from a global ETS-like
  table managed by the runtime, with no process dependency. It does not consult
  the `SettingsCache` GenServer on reads and therefore cannot crash because the
  GenServer is absent. The `rescue`/`catch` arms guard against an exception that
  the current implementation cannot produce.
- **Qualifier (Q):** This claim is about the current `SettingsCache` implementation
  as of `cache.ex` revision read above. If SettingsCache were changed to use a
  `GenServer.call` on reads (e.g., if `:persistent_term` were replaced with a
  direct ETS or a `call`-based API), the failure mode would change and the
  `rescue` arms could become load-bearing.
- **Rebuttal (R):** The problem.md §Context states "`SettingsCache.get/0` can
  crash if the cache process is not started or its ETS table is absent during
  test isolation or mis-sequenced startup." This was written as a statement of
  fact, but it contradicts the actual implementation. The problem statement
  is empirically wrong about the failure mode of the current code.
- **Backing (B):** `lib/tau/settings/cache.ex:28` (read above); Erlang/OTP
  `:persistent_term` module documentation (erlang.org/doc/man/persistent_term.html
  — `get/2` returns Default when Key is not found, no exception); solution.md
  §Open questions Q1 (self-noted "medium confidence").

#### Falsification attempt for claim 3

- **Strategy:** Dependency check — verify the actual failure mode of
  `SettingsCache.get/0` by reading `lib/tau/settings/cache.ex`.
- **Attempt:** Read `cache.ex` in full (read above). `get/0` is implemented as
  `:persistent_term.get(@persistent_key, %{})`. This is a lock-free read from
  the persistent-term table with `%{}` as the explicit default. There is no
  `GenServer.call`, no ETS lookup that would raise on missing table, and no
  code path that raises in `get/0`. Therefore the `rescue`/`catch` arms in the
  current and proposed code guard against an exception that the current
  implementation does not produce.
- **Outcome:** Partially falsified — the claim that `rescue`/`catch` is
  load-bearing because `SettingsCache.get/0` raises on cache-process absence
  is false for the current implementation. The qualifier must be narrowed:
  "the `rescue`/`catch` arms are defensive guards against a future
  implementation change to SettingsCache, not against the current failure mode."
- **Action:** Narrow qualifier in place. No solution revision required. The
  solution's correctness is unaffected: retaining dead-code `rescue`/`catch`
  is conservative and harmless. The open question Q1 in solution.md accurately
  flags this uncertainty; the implementer should document the finding (as
  solution.md already instructs). The problem.md §Context claim that
  "SettingsCache.get/0 can crash if the cache process is not started" is
  empirically wrong but does not invalidate the acceptance criterion or the fix.

---

### Claim 4: No external callers of maybe_start_tau_context/1 or expose_tau_context?/0 are affected

- **Claim (C):** "External callers of `maybe_start_tau_context/1` — both
  functions are private; no public API change." (solution.md §What does not
  change)
- **Grounds (G):** `expose_tau_context?/0` is `defp` at `dispatcher.ex:384`.
  `maybe_start_tau_context/1` is `defp` at `dispatcher.ex:344`. Grep results
  above show no cross-module call site.
- **Warrant (W):** Same as Claim 2 warrant — Elixir `defp` enforces module-local
  visibility at compile time; no other module can hold a reference that the
  compiler would resolve.
- **Qualifier (Q):** Absent dynamic dispatch (`apply/3`) cross-module, which the
  grep confirmed is absent.
- **Rebuttal (R):** Same caveat as Claim 2; no practical rebuttal found.
- **Backing (B):** Elixir language spec; confirmed by grep above.

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration — consider whether test helpers or
  macros could create cross-module references to private functions.
- **Attempt:** Searched `test/` directory for references to
  `maybe_start_tau_context` and `expose_tau_context` (grep above). No test
  file references either function by name. No `ExUnit.Case` callback, no
  `defmacro` injection found that would synthesize a call.
- **Outcome:** Withstood — no external callers found in production or test code.
- **Action:** None.

---

### Claim 5: The telemetry event name [:tau, :coding_agent, :tau_context, :settings_unavailable] follows the existing namespace convention

- **Claim (C):** "Telemetry event name convention — the `:settings_unavailable`
  event follows existing `[:tau, :coding_agent, ...]` namespace."
  (solution.md §What does not change)
- **Grounds (G):** `dispatcher.ex:361–366` emits
  `[:tau, :coding_agent, :tau_context, :start_failed]` today. SPEC-CODING-AGENT
  §4 lists `[:tau, :coding_agent, :start]`, `[:tau, :coding_agent, :event]`,
  `[:tau, :coding_agent, :stop]`, `[:tau, :coding_agent, :exception]`. The
  proposed event `[:tau, :coding_agent, :tau_context, :settings_unavailable]`
  shares the `[:tau, :coding_agent, :tau_context, ...]` prefix with the existing
  `:start_failed` event.
- **Warrant (W):** OTP non-negotiable rule 5: "Telemetry events MUST cover
  everything user-visible or perf-sensitive … in `[:tau, ...]`". The four-tuple
  namespacing `[:tau, :coding_agent, :tau_context, :event_name]` is the
  established pattern for tau-context lifecycle events within the coding-agent
  subsystem.
- **Qualifier (Q):** Holds for the naming convention; no claim is made about
  there being a registered consumer. Solution.md §Open questions Q3 explicitly
  flags the absence of a documented consumer.
- **Rebuttal (R):** If a telemetry consumer does strict prefix-matching on
  `[:tau, :coding_agent, :tau_context]`, the new event is automatically
  captured. If consumers enumerate event names explicitly, the new event may
  be silently dropped. The solution does not add a consumer.
- **Backing (B):** OTP non-negotiable rule 5; `dispatcher.ex:361–366` (existing
  `:start_failed` event establishing the prefix pattern); SPEC-CODING-AGENT §4
  telemetry section.

#### Falsification attempt for claim 5

- **Strategy:** Edge-case enumeration — check whether any existing telemetry
  consumer enumerates event names explicitly in a way that would exclude the
  new event.
- **Attempt:** Grep for telemetry consumers of the `[:tau, :coding_agent, ...]`
  namespace in `lib/` and `test/`. The source map (SPEC-CODING-AGENT Appendix B)
  does not list a dedicated telemetry consumer module for this namespace.
  The event is fired and forgotten (fire-and-observe pattern); no consumer
  exclusion would prevent the event from being emitted.
- **Outcome:** Withstood — the naming claim holds. The absence of a consumer
  is noted in solution.md §Open questions Q3 and does not falsify the naming
  convention claim.
- **Action:** None.

---

## Cross-claim consistency

Claims 1 and 3 are in mild tension: Claim 1 argues the solution satisfies the
acceptance criterion by structural distinguishability; Claim 3's partial
falsification reveals the `:error` branch is unreachable in the current
production implementation, meaning the test for the criterion must rely on
mocking. This tension does not invalidate either claim — it shifts the
verification burden from "observable in production" to "testable via mock" —
but it should be documented in the PR (and solution.md §Open questions Q1
already anticipates it). No irreconcilable contradiction between claims was
found.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Rename + tagged tuple satisfies AC | Dependency check | Withstood | None |
| 2 | All changes confined to dispatcher.ex | Counter-example construction | Withstood | None |
| 3 | rescue/catch arms are load-bearing | Dependency check | Partially falsified | Narrow qualifier: arms are defensive, not currently triggered |
| 4 | No external callers affected | Edge-case enumeration | Withstood | None |
| 5 | Telemetry event follows namespace convention | Edge-case enumeration | Withstood | None |

---

## Revision required

Claim 3 is partially falsified; qualifier narrowed in place. No solution or
problem revision is required. The solution's recommendation remains sound:
the tagged-tuple approach correctly satisfies the acceptance criterion.

The problem.md §Context claim "SettingsCache.get/0 can crash if the cache
process is not started" is empirically inaccurate for the current
implementation, but this does not invalidate the acceptance criterion or the
fix's correctness. The implementer must document this finding in the PR per
solution.md §Open questions Q1.

- **Target file:** N/A
- **Revision kind:** N/A — qualifier narrowed in place; no file revision
  triggered
- **Rationale:** The falsification narrows the scope of claim 3 (arms are
  conservative dead-code guards, not active error handlers) but does not change
  the solution's correctness or the recommendation. Retaining dead-code
  `rescue`/`catch` is harmless; the tagged-tuple form satisfies the criterion
  under the actual implementation.

---

## Outstanding doubts

1. **SettingsCache.get/0 never raises — test strategy.** The `{:error,
   :cache_unavailable}` branch in the proposed `fetch_expose_tau_context/0`
   is unreachable in production with the current `:persistent_term`-backed
   implementation. The test case solution.md §Migration sketch specifies
   ("SettingsCache raises → state unchanged + telemetry fired") will need to
   mock or override `SettingsCache.get/0` to force a raise. The test is valid
   and should be written (it protects against future `SettingsCache` contract
   changes), but the PR should clarify how the mock is constructed and note
   that the production path does not exercise this branch today.

2. **problem.md §Context accuracy.** The statement "SettingsCache.get/0 can
   crash if the cache process is not started or its ETS table is absent during
   test isolation or mis-sequenced startup" is incorrect for the current
   implementation (`:persistent_term.get/2` with default has no process
   dependency). This is a minor documentation inaccuracy in the problem
   statement; it does not affect the solution's validity but could mislead a
   future reader of the problem tree. The coordinator may wish to log an
   amendment to problem.md for historical accuracy.

3. **Telemetry consumer gap.** The `:settings_unavailable` event is emitted
   but has no documented consumer (solution.md §Open questions Q3). If the
   event is the only signal of the fail-closed decision, silent degradation
   goes unmonitored unless an operator has wired a telemetry sink. This is
   not a blocker but should be tracked.
