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

# Validation: Thread `instance_id` through `Application.start/2`; derive names via `Tau.Names`; store in `:persistent_term`

## Overview

The solution asserts that a new `Tau.Names` struct module plus a one-shot
`:persistent_term` publish at `Application.start/2`, combined with `name:` /
`table:` opts on `CircuitBreaker.Store` / `Cost.Tracker` and a `names:` opt on
`Tau.Registries`, eliminates both the test-fixture and the production
multi-tenant single-instance collision while preserving the default deployment
behaviour. This validation extracts **8 claims** from the Recommendation,
What-changes, and What-does-not-change sections, runs full Toulmin on each,
and applies an explicit falsification strategy per claim. Outcome: 7 claims
withstood; **Claim 3 is partially falsified** — the solution's "~five-line
change" / "~30 call sites" sizing is an under-estimate (the Store/Tracker
module-internal `@table` attribute is referenced at 10 + 3 ETS call sites
that must all be converted to runtime lookup; total call-site sweep is
≥176 across `lib/` + `test/`). The narrowed qualifier does not change the
chosen approach; no revision is triggered.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: `Tau.Names.compute/1` is a pure derivation; `:persistent_term` store is set once at startup and read at O(1) cost; the `:default` clause preserves all existing atoms.

- **Claim (C):** A new `Tau.Names` struct module exposes `compute/1` (pure)
  + `get/0`/`get/1` (reads from `:persistent_term`), populated once by
  `Application.start/2`; `compute(:default)` returns exactly the current
  module atoms (`Tau.PubSub`, `Tau.Providers.Finch`, `Tau.CircuitBreaker.Store`,
  `:tau_circuit_breakers`, `Tau.Cost.Tracker`, `:tau_cost_counters`,
  `Tau.Supervisor`, the seven `Registry` atoms).
- **Grounds (G):** Proposal 2's sketch defines the struct with 16 fields and
  the `:default` clause verbatim (`proposals/proposal-2.md:101-120`). The
  current named-children atoms are observable at
  `lib/tau/application.ex:68` (`Tau.PubSub`),
  `lib/tau/application.ex:78` (`Tau.Providers.Finch`),
  `lib/tau/application.ex:80` (`Tau.CircuitBreaker.Store`),
  `lib/tau/application.ex:93` (`Tau.Supervisor`),
  `lib/tau/registries.ex:56-63` (seven `Registry` atoms),
  `lib/tau/circuit_breaker/store.ex:47` (`:tau_circuit_breakers`), and
  `lib/tau/cost/tracker.ex:60` (`:tau_cost_counters`).
  `:persistent_term`'s read characteristics are documented at
  https://www.erlang.org/doc/man/persistent_term — reads are constant time and
  do not copy small terms.
- **Warrant (W):** A pure function whose output is fixed at startup and
  published to a read-mostly term store is the standard BEAM idiom for
  zero-overhead configuration distribution; this matches the existing pattern
  at `lib/tau/settings/cache.ex:48` (`:persistent_term.put`) +
  `lib/tau/settings.ex:14` (`:persistent_term.get`).
- **Qualifier (Q):** Holds provided `Application.start/2` writes `:tau_names`
  before any child reads it (sequential within `start/2` — safe) and provided
  no caller mutates the published struct after startup (it is a record value,
  not a process).
- **Rebuttal (R):** A test that calls `Tau.Names.get/0` before
  `Application.start/2` has been re-entered with the new code (e.g. an
  earlier-loaded test harness) sees `:undefined`. The `get/0` default-arg
  semantics must specify a fallback (or pass-through to the historical atoms)
  to avoid breaking the "tests that don't start a second instance" promise.
- **Backing (B):** OTP-NN §1 ("stateful subsystems run as supervised processes;
  no module-level mutable state") is not violated because `:persistent_term`
  is published exactly once at supervisor startup, not on a runtime write path
  — the pattern is the same `Tau.Settings.Cache` already follows
  (`lib/tau/settings/cache.ex:3-28`). Erlang/OTP documentation on
  `:persistent_term` is the type-level authority.

#### Falsification attempt for claim 1

- **Strategy:** Dependency check + counter-example construction.
- **Attempt:** (1) Confirmed `:persistent_term` is in use in this codebase at
  the cited Settings cache sites and 5 other modules
  (`tui/runtime_opts.ex:38,42,45`, `tool/validator.ex:81,92,99`,
  `coding_agent/tau_context.ex:249,259`, `coding_agent/tau_context/router.ex:336`),
  so the BEAM build does support it. (2) Attempted to construct a code state
  where `compute(:default)` would NOT round-trip the historical atoms:
  inspected `proposals/proposal-2.md:110-120` and matched each field to the
  current source-of-truth atom. All 9 atoms named in the `:default` branch
  match observable startup atoms. (3) Attempted to construct a caller that
  reads `Tau.Names.get/0` before `Application.start/2` runs — possible only
  in a module-attribute or compile-time context, which is the genuine
  rebuttal already conceded.
- **Outcome:** withstood (subject to the documented rebuttal — `get/0` must
  have a `:default`-bearing fallback, which the solution's "regression
  baseline" step 6 implies).
- **Action:** None; carry the rebuttal forward as an implementation note.

### Claim 2: Both the test-fixture and production multi-tenant collision scenarios are resolved by Proposal 2 in one atomic change.

- **Claim (C):** A second Tau OTP application started in the same BEAM with
  a distinct `instance_id` no longer collides on `Tau.PubSub`,
  `Tau.Providers.Finch`, `Tau.CircuitBreaker.Store`, `Tau.Cost.Tracker`,
  `Tau.Supervisor`, any of the seven `Registry` children, or the ETS tables.
- **Grounds (G):** All process registrations the second instance would
  otherwise collide on are passed through `name:` opts at
  `proposals/proposal-2.md:54-71`, and ETS tables are created via the
  parameterised `table:` opt (sketch lines 63, 88-89 of proposal-2). The
  collision-producing sites today are enumerated in `problem.md:26-39`
  and verified against the source: `lib/tau/application.ex:68,78,80,93`,
  `lib/tau/circuit_breaker/store.ex:65`, `lib/tau/cost/tracker.ex:73`,
  `lib/tau/registries.ex:51,56-63`.
- **Warrant (W):** A process registration collision in BEAM is caused only
  by two `start_link` calls supplying the same `name:` atom; removing the
  hard-coded names by threading parameterised atoms removes the structural
  cause. Same logic applies to `:named_table` ETS: distinct atoms → distinct
  tables.
- **Qualifier (Q):** Holds for *the named registrations enumerated above*.
  Does NOT speak to anonymous-but-globally-discovered resources (e.g. a
  `:global` registration — none observed in the cited grounds, consistent
  with `.claude/rules/otp-non-negotiables.md` §4) or to shared file-system
  state (out of scope for this node).
- **Rebuttal (R):** If a downstream library called by Tau (e.g. a Finch
  pool plug or a Phoenix.PubSub adapter) registers its own auxiliary
  process under a hard-coded atom keyed on the parent name, two instances
  could collide there. The fix would land in that downstream library, not
  in `Tau.Names`. Not observed in current Tau code.
- **Backing (B):** OTP `Registry` and `gen_server` `name:` semantics
  (Erlang/OTP documentation, https://www.erlang.org/doc/man/gen_server#start_link-4).

#### Falsification attempt for claim 2

- **Strategy:** Edge-case enumeration over the named-resource set from
  `problem.md`.
- **Attempt:** Walked each of the 7 named children in
  `lib/tau/registries.ex:56-63` plus the 4 in `lib/tau/application.ex` plus
  the 2 ETS tables. For each, confirmed proposal-2's sketch threads the
  parameterised atom. Additionally checked for indirect bare-atom
  references: `grep -rn "Tau\.PubSub\|Tau\.Providers\.Finch" lib/` returns
  25 hits, and the seven `Registry` atoms return 63 hits in `lib/` — all
  would need conversion to `Tau.Names.get().<field>`; the proposal commits
  to this sweep in `solution.md:101-103`.
- **Outcome:** withstood. The structural cause of collision is removed for
  every site enumerated.
- **Action:** None.

### Claim 3: Call-site churn is "~30 locations", "entirely mechanical and verifiable with grep"; the change to `Store` / `Tracker` is "a five-line change each".

- **Claim (C):** The total mechanical edit fan-out is bounded at roughly
  30 call sites (per `solution.md:101-103`) and the `CircuitBreaker.Store`
  / `Cost.Tracker` modifications are "a five-line change to accept `name:`
  and `table:` opts" (per `solution.md:23-24`).
- **Grounds (G):** `solution.md:101-103` cites the grep:
  `Tau\.PubSub\|Tau\.Providers\.Finch\|Tau\.Tools\.Registry\|Tau\.Sessions\.Registry`.
  Measured today against `lib/`: `Tau.PubSub | Tau.Providers.Finch` → 25
  hits; seven `Registry` atoms → 63 hits; **total 88 in `lib/` alone**.
  Adding `test/`: `Tau.PubSub | Tau.Providers.Finch` → 151 hits;
  registry atoms not separately counted but non-zero. The Store's `@table`
  module attribute is referenced in 10 internal ETS call sites
  (`lib/tau/circuit_breaker/store.ex:56,76,89,102,118,133,186,247,269`)
  and Tracker's `@table` at 3 sites (`lib/tau/cost/tracker.ex:77,81,130,155`).
  Each of those references must be converted from a compile-time module
  attribute to a runtime lookup (`opts[:table]` → state field), which is
  more than five lines per module.
- **Warrant (W):** Code metric: the solution's edit fan-out can be bounded
  only by counting actual reference sites at named atoms. A module attribute
  embedded in macro-expanded `:ets.update_counter(@table, …)` calls is
  expanded at compile time to the literal atom; converting to runtime
  requires changing both the `init/1` to store the table name in state and
  every call site to thread that state.
- **Qualifier (Q):** The claim survives in narrowed form: the conversion is
  still "entirely mechanical and grep-verifiable" and the per-site change
  is small, but the absolute count is materially higher than 30 in `lib/`
  alone and well above 100 once `test/` files (151 hits for PubSub/Finch
  alone) are included; the Store/Tracker edit is closer to 15-25 lines per
  module than 5.
- **Rebuttal (R):** If the implementer chooses to leave the `@table`
  module attribute as the default *fallback* and only consults
  `opts[:table]` when one is supplied (i.e. `@table` is kept as a
  compile-time default), the per-module edit can stay near the five-line
  target — at the cost of two parallel code paths in `Store` and
  `Tracker`. This rebuttal does not save the "~30 sites" figure.
- **Backing (B):** Observable grep results in the current repo (counted
  above) and the file-level structure of
  `lib/tau/circuit_breaker/store.ex` / `lib/tau/cost/tracker.ex`.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction (count the actual sites).
- **Attempt:** Ran `grep -rn "Tau\.PubSub\|Tau\.Providers\.Finch" lib/`
  → 25; `grep -rn "Tau\.Tools\.Registry\|Tau\.Sessions\.Registry\|
  Tau\.Hooks\.Registry\|Tau\.Commands\.Registry\|Tau\.Skills\.Registry\|
  Tau\.MCP\.Registry\|Tau\.Providers\.RateLimiter\.Registry" lib/` → 63;
  `grep -rn "Tau\.PubSub\|Tau\.Providers\.Finch" test/` → 151. Inspected
  `lib/tau/circuit_breaker/store.ex` for `@table` occurrences → 10 internal
  ETS call sites; `lib/tau/cost/tracker.ex` for `@table` → 3 internal
  sites. The total mechanical conversion fan-out is several-fold larger
  than "~30".
- **Outcome:** **partially falsified.** The chosen approach still works —
  the conversion remains mechanical and grep-verifiable — but the
  cost-estimate granularity in `solution.md` understates the real edit
  surface by a factor of 3-6×. Implementer must size the work accordingly.
- **Action:** Narrow Qualifier in place (done above). No revision to the
  chosen approach is required; flag in **Outstanding doubts** for the
  parent validator to inherit so PR-sizing decisions are realistic. The
  selector's preference for P2 over P4 ("Medium" migration cost) is
  unchanged because P4's cost was rated "High" and that ordering is
  preserved even with the corrected P2 size.

### Claim 4: `:persistent_term`-stored names introduce no hot-path latency overhead vs the current bare-atom dispatch.

- **Claim (C):** Reading `Tau.Names.get().<field>` on every hot-path
  PubSub broadcast / Finch request / Registry lookup adds zero
  measurable latency compared with the current literal-atom usage.
- **Grounds (G):** `:persistent_term.get/2` is a constant-time
  unboxed-term read (Erlang docs:
  https://www.erlang.org/doc/man/persistent_term#description). The
  existing `Tau.Settings.Cache.get/0` uses the same pattern on hot paths
  with no observed regression
  (`lib/tau/settings/cache.ex:28`; `lib/tau/settings.ex:14`).
- **Warrant (W):** A read-mostly term published once and read many is
  precisely the workload `:persistent_term` is engineered for; copying
  the term into the calling process is avoided when the term is small
  (the names struct holds 16 atoms — small).
- **Qualifier (Q):** Holds provided the names struct stays small (< a
  few hundred bytes) and is not republished on a hot path. Both
  conditions are satisfied by the solution's "set once at startup" design.
- **Rebuttal (R):** If a future commit republishes the names term on
  every settings reload (i.e. via `Watcher`), every running process
  triggers a global GC by Erlang's persistent-term semantics. The
  solution does NOT do this, but the door is open.
- **Backing (B):** Erlang/OTP `persistent_term` documentation
  (https://www.erlang.org/doc/man/persistent_term) — explicitly recommends
  this pattern for read-mostly configuration distribution; warns against
  frequent puts (GC cost).

#### Falsification attempt for claim 4

- **Strategy:** Performance/scaling check (informal complexity analysis).
- **Attempt:** Compared the hot-path operation count under current code
  (literal atom load, ≈ 0 cycles) vs proposed (one `:persistent_term.get/1`
  + one struct field access ≈ low single-digit nanoseconds). The pattern
  is already in production via `Tau.Settings.Cache` with no regression.
- **Outcome:** withstood.
- **Action:** None.

### Claim 5: D-044 (circuit-breaker ETS row-layout schema version) does NOT need to be bumped.

- **Claim (C):** The ETS table *name* parameterisation is independent of
  the row schema; `@schema_version` stays at 1.
- **Grounds (G):** D-044 is scoped to the **positional field layout** of
  the row (`docs/spec/SPEC-CIRCUIT-BREAKER.md:294-300` and inline at
  `lib/tau/circuit_breaker/store.ex:24-48`): "Field positions MUST NOT
  be renumbered without bumping `@schema_version`". Renaming the table
  changes no field positions; `update_counter` and `select_replace`
  still operate on the same {provider_key, state_atom, failure_count,
  success_count, opened_at_ms, probe_slot} tuple.
- **Warrant (W):** D-044's invariant is structural (row-layout), not
  identity (table-name). The schema-version mechanism guards data
  migration semantics, which are unaffected by renaming the container.
- **Qualifier (Q):** Holds provided no PR also alters row positions in
  the same change. The solution explicitly disclaims field-layout
  edits (`solution.md:118`).
- **Rebuttal (R):** If a future migration tool keys cached schema state
  by `{table_name, schema_version}` rather than `schema_version` alone,
  the renaming could surface as a transient version mismatch. No such
  tool exists today (`grep -rn "schema_version" lib/` shows
  `Store.schema_version/0` only; no consumer cache).
- **Backing (B):** `docs/spec/SPEC-CIRCUIT-BREAKER.md:294-300` (D-044
  text) is the authoritative source.

#### Falsification attempt for claim 5

- **Strategy:** Dependency check (read the D-044 spec text).
- **Attempt:** Read the cited D-044 paragraph; confirmed scope is "row
  layout" / "field positions" only. Checked for downstream consumers of
  `Store.schema_version/0` via grep — none beyond the Store itself.
- **Outcome:** withstood.
- **Action:** None.

### Claim 6: All `start_link/1` external signatures remain backward-compatible for the `:default` instance.

- **Claim (C):** Existing callers of `Tau.CircuitBreaker.Store.start_link/1`,
  `Tau.Cost.Tracker.start_link/1`, `Tau.Registries.start_link/1`, and the
  flow at `Tau.Application.start/2` continue to work unchanged when
  `instance_id` is `:default`.
- **Grounds (G):** Proposal 2's `start_link/1` modifications take `opts`
  with defaults (`name: __MODULE__`, `table: :tau_circuit_breakers`),
  preserving the call-site shape. Today's signatures are
  `def start_link(opts \\ [])` at `lib/tau/circuit_breaker/store.ex:65`
  and `lib/tau/cost/tracker.ex:73`. Defaults preserve historical atoms
  (per solution.md:23-24 + proposal-2.md sketch).
- **Warrant (W):** Adding new opt keys with defaults is a backward-
  compatible Elixir API change; callers that pass no opts get the
  prior behaviour.
- **Qualifier (Q):** Holds for callers that pass at most an empty
  keyword list. A caller that already passes a `name:` opt would
  have its value preserved.
- **Rebuttal (R):** If `Tau.Registries.init/1` currently disregards
  opts (today it pattern-matches `init(_opts)` at `lib/tau/registries.ex:54`),
  changing the signature to read `opts[:names]` and threading per-child
  names is backward-compatible only if missing `:names` produces a
  defaulted name set — the proposal's `Tau.Application.start/2` change
  explicitly threads `names: Tau.Names.compute(:default)` (step 3 of
  migration), so this holds; without that, internal-only callers
  break.
- **Backing (B):** Elixir keyword-list opts convention (Elixir Style
  Guide); current Tau pattern at `lib/tau/registries.ex:51`
  (`Supervisor.start_link(__MODULE__, opts, name: __MODULE__)`).

#### Falsification attempt for claim 6

- **Strategy:** Type-level / API-shape check.
- **Attempt:** Inspected the current `start_link/1` arities and
  `init/1` shapes for the three modules. Confirmed all accept `opts`
  today and the modifications keep arity and add defaults rather
  than required positional args.
- **Outcome:** withstood.
- **Action:** None.

### Claim 7: Test files that do not start a second instance compile and pass without change.

- **Claim (C):** The `mix test` suite continues green after the change
  for tests that exercise only the `:default` instance.
- **Grounds (G):** Defaults preserve historical atoms (per Claim 1 +
  Claim 6); test fixtures keying on those atoms (e.g.
  `test/tau/circuit_breaker/store_property_test.exs:20` —
  `@table Store.table()`) read through the `Store.table/0` accessor,
  which would now read the runtime-stored table name but for
  `:default` still returns `:tau_circuit_breakers`.
- **Warrant (W):** Backward-compatible defaults + accessor-mediated
  table-name access = test invariance for the default instance.
- **Qualifier (Q):** Holds for tests that (a) do not start a second
  Tau instance and (b) access ETS table names via `Store.table/0` /
  `Tracker.table/0` rather than hard-coded `:tau_circuit_breakers` /
  `:tau_cost_counters` literals. Today there are no test files
  hard-coding those literals (`grep -rn ":tau_circuit_breakers\|
  :tau_cost_counters" test/` returns one documentation comment at
  `test/tau/cost_test.exs:8` — non-load-bearing).
- **Rebuttal (R):** A test that snapshots `:erlang.registered/0` and
  asserts on specific atoms would see ordering / membership changes
  if the supervisor's own name is parameterised. No such test
  observed via grep.
- **Backing (B):** Same Elixir-opts/default-arg convention as Claim 6.

#### Falsification attempt for claim 7

- **Strategy:** Counter-example construction over `test/` for direct
  reliance on hard-coded ETS table atoms.
- **Attempt:** Ran `grep -rn ":tau_circuit_breakers\|:tau_cost_counters"
  test/`. Only hit is a comment in `test/tau/cost_test.exs:8`. No
  test depends on the literal atom directly.
- **Outcome:** withstood.
- **Action:** None.

### Claim 8: P2 is strictly preferable to P1 / P3 / P4 on the stated scoring criteria.

- **Claim (C):** Per the scoring table in `solution.md:47-53`, P2
  dominates P1 (Surface vs Deep, P1 violates OTP-NN §1), P3 (P3 adds
  GenServer hop, no benefit for read-mostly data), and P4 (P4 is
  Hard reversibility / High cost with bootstrapping uncertainty).
- **Grounds (G):** Scoring rationale at `solution.md:55-83`:
  - P1: `Application.put_env/3` for runtime state — explicit OTP-NN §1
    violation (`.claude/rules/otp-non-negotiables.md`).
  - P3: GenServer name resolution adds a mailbox hop per dispatch
    vs `:persistent_term.get/1` constant-time read.
  - P4: Pure `{:via, Registry, ...}` requires self-bootstrapping the
    instance registry — open prototype question; API-breaking
    `start_link/1` changes are not easily revertible.
- **Warrant (W):** Standard engineering-trade-off ranking: an approach
  that satisfies all acceptance criteria at bounded cost with reversible
  changes is preferred over one that adds runtime overhead with no
  capability gain (P3), violates a stated invariant (P1), or commits
  to an irreversible structural shift without a prototype (P4).
- **Qualifier (Q):** Holds *for the immediate landing of this
  decomposition*. P4 remains the eventual destination; P2 explicitly
  positions `Tau.Names.compute/1` as a substitutable layer that a
  future `{:via, ...}` derivation can replace without call-site
  churn (`solution.md:78-83`).
- **Rebuttal (R):** If a future requirement forces dynamic
  per-session name allocation (e.g. each session has its own
  PubSub topic-space), a `Tau.Instance` GenServer or `{:via, ...}`
  registration becomes preferable. P2 does not preclude this
  evolution.
- **Backing (B):** OTP-NN invariants (`.claude/rules/otp-non-negotiables.md`),
  the design-reasoning skill's reversibility/migration-cost matrix
  (referenced in `CLAUDE.md` → `design-reasoning`).

#### Falsification attempt for claim 8

- **Strategy:** Prior-art counter-case + dependency check.
- **Attempt:** (1) Confirmed `:persistent_term`-as-name-cache pattern
  is already accepted in this codebase (`Tau.Settings.Cache`,
  `Tau.TUI.RuntimeOpts`, `Tau.Tool.Validator`) — no prior-art counter-case
  internally. (2) Confirmed P1's reliance on `Application.put_env/3`
  for runtime state is forbidden by `.claude/rules/otp-non-negotiables.md`
  §1 (module-level mutable state via `Application.put_env/3`). (3) P3's
  GenServer hop on a read-mostly path is unjustifiable when
  `:persistent_term` provides O(1) reads without supervised
  lifecycle.
- **Outcome:** withstood.
- **Action:** None.

## Cross-claim consistency

Claims are internally consistent. Two tensions exist and both resolve:

1. **Claim 3 (partial falsification on cost) vs Claim 8 (P2 chosen on cost
   grounds).** If P2's true cost is 3-6× larger than estimated, does that
   change the P2-vs-P4 ranking? Resolution: P4's cost was rated "High" and
   includes API-breaking `start_link/1` changes plus a prototype to resolve
   the bootstrapping question. Even with P2's true cost upgraded from "low
   end of Medium" to "high end of Medium / low end of High", P4's
   irreversibility (Hard) and prototype-dependency remain decisive. The
   ranking holds.

2. **Claim 5 (D-044 unaffected) vs Claim 3 (Store internals change).** The
   internal `@table → opts[:table]` conversion touches `init/1`,
   `lookup/2`, `update_counter/3`, `select_replace/2` call sites but
   changes **no row positions**. D-044's invariant is scoped to row
   positions only; the table-name change is orthogonal. Consistent.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `Tau.Names.compute/1` pure; `:persistent_term` O(1); `:default` preserves atoms | dependency + counter-example | withstood | none |
| 2 | Both test-fixture and prod multi-tenant collisions resolved | edge-case enumeration | withstood | none |
| 3 | ~30 call sites; 5-line module change; "entirely mechanical" | counter-example (count sites) | partially falsified | narrow qualifier (done); flag for PR sizing |
| 4 | `:persistent_term` reads add no hot-path latency | performance/scaling | withstood | none |
| 5 | D-044 schema version not bumped | dependency check | withstood | none |
| 6 | `start_link/1` signatures backward-compatible for `:default` | type/API check | withstood | none |
| 7 | Tests that don't start a second instance pass unchanged | counter-example over `test/` | withstood | none |
| 8 | P2 dominates P1/P3/P4 on scoring criteria | prior-art + dependency | withstood | none |

## Revision required

None. Claim 3's partial falsification narrows a Qualifier — the chosen
approach (P2) still satisfies all acceptance-criterion sub-questions and
the scoring ranking holds (see cross-claim resolution 1). The solution
does not require structural revision; the implementer must, however,
plan the PR's size honestly.

- **Target file:** n/a
- **Revision kind:** n/a
- **Rationale:** Narrowed Qualifier on Claim 3 is documented in place;
  no structural change to solution.md required.

## Outstanding doubts

These propagate to the parent-level validator:

- **PR sizing.** The "~30 call sites" estimate understates by 3-6×; real
  conversion surface in `lib/` is ≥88 sites and in `test/` ≥151 hits for
  PubSub/Finch alone. The Store/Tracker per-module edit is closer to
  15-25 lines than 5. Parent should expect a medium-to-large PR, not a
  small one, when this lands. This MAY argue for splitting along the
  step boundaries in `solution.md:121-138`'s migration sketch (six
  discrete steps, each green-able independently).
- **`Tau.Names.get/0` fallback semantics.** The solution does not
  explicitly specify what `get/0` returns when `:tau_names` has not
  been published (e.g. a compile-time call before `Application.start/2`).
  Implementer should default to the `:default` name set or raise with
  a diagnostic message.
- **Tests that snapshot `:erlang.registered/0`.** None observed today,
  but if added in future, would couple to the supervisor naming and
  break under non-`:default` instances. Worth a guard test that
  asserts the `:default` instance round-trips the historical atom set.
- **Downstream-library auxiliary registrations.** Phoenix.PubSub and
  Finch internal helper processes (e.g. pool supervisors) may register
  under derived atoms that are themselves keyed off the parent name —
  no collision observed today, but if a future upgrade introduces one,
  the fix lands in the dependency, not in `Tau.Names`. Flag for
  release-notes review when upgrading those libs.
